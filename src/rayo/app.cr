require "./sys"
require "./http"
require "./router"
require "./context"
require "./server"

module Rayo
  class App
    getter router = Router.new
    @before = [] of Router::Handler
    @after = [] of Router::Handler

    {% for method in %w(get post put patch delete options head) %}
      def {{method.id}}(path : String, &block : Context -> Nil) : Nil
        @router.add(HTTP::Method::{{method.upcase.id}}, path, block)
      end
    {% end %}

    def before(&block : Context -> Nil) : Nil
      @before << block
    end

    def after(&block : Context -> Nil) : Nil
      @after << block
    end

    def dispatch(ctx : Context) : Nil
      @before.each &.call(ctx)
      @router.dispatch(ctx)
    end

    def after_response(ctx : Context) : Nil
      @after.each &.call(ctx)
    end

    private def reset_signals : Nil
      # The loop uses raw syscalls, so inherited stdlib signal handlers cannot run.
      LibC.signal(15, LibC::SIG_DFL)
      LibC.signal(2, LibC::SIG_DFL)
      mask = uninitialized LibC::SigsetT
      LibC.sigemptyset(pointerof(mask))
      LibC.sigaddset(pointerof(mask), 15)
      LibC.sigaddset(pointerof(mask), 2)
      LibC.pthread_sigmask(1, pointerof(mask), Pointer(LibC::SigsetT).null)
    end

    private def worker(host : String, port : Int32, workers : Int32) : NoReturn
      reset_signals
      fd = listen(host, port)
      unless Uring.setup(pointerof(fd), 1, Sys.raise_nofile, workers)
        LibC.close(fd)
        raise "io_uring setup failed (Linux 6.1+ required)"
      end
      Server.init(self, Uring.capacity)
      Uring.run
    end

    private def listen(host : String, port : Int32) : Int32
      fd = LibC.socket(Sys::AF_INET, Sys::SOCK_STREAM | Sys::SOCK_NONBLOCK | Sys::SOCK_CLOEXEC, 0)
      raise "socket failed" if fd < 0
      one = 1
      begin
        {Sys::SO_REUSEADDR, Sys::SO_REUSEPORT}.each do |option|
          raise "setsockopt failed" if LibC.setsockopt(fd, Sys::SOL_SOCKET, option, pointerof(one).as(Void*), 4) != 0
        end
        addr = Sys::SockaddrIn.new
        addr.sin_family = Sys::AF_INET.to_u16
        addr.sin_port = ((port & 255) << 8 | (port >> 8) & 255).to_u16
        addr.sin_addr = LibSys.inet_addr(host.to_unsafe)
        raise "invalid IPv4 address" if addr.sin_addr == UInt32::MAX && host != "255.255.255.255"
        raise "bind failed (errno #{Sys.errno})" if LibC.bind(fd, pointerof(addr).as(LibC::Sockaddr*), sizeof(Sys::SockaddrIn).to_u32) != 0
        raise "listen failed" if LibC.listen(fd, 65535) != 0
      rescue ex
        LibC.close(fd)
        raise ex
      end
      fd
    end

    def run(host = "0.0.0.0", port = 3000, workers = Sys.ncpu) : NoReturn
      raise ArgumentError.new("workers must be positive") if workers < 1
      raise ArgumentError.new("invalid port") unless 0 <= port <= 65535
      worker(host, port, 1) if workers == 1
      reset_signals
      pids = [] of Int32
      begin
        workers.times do
          parent = LibC.getpid
          pid = LibC.fork
          raise "fork failed" if pid < 0
          if pid == 0
            LibSys.prctl(1, 15_u64)
            LibC._exit(1) if LibC.getppid != parent
            begin
              worker(host, port, workers)
            rescue ex
              STDERR.puts ex.message
              LibC._exit(1)
            end
          end
          pids << pid
        end
        status = 0
        loop do
          dead = LibC.waitpid(-1, pointerof(status), 0)
          next if dead < 0 && Sys.errno == Sys::EINTR
          pids.delete(dead)
          break
        end
      ensure
        pids.each { |pid| LibC.kill(pid, 15) }
        pids.each do |pid|
          status = 0
          while LibC.waitpid(pid, pointerof(status), 0) < 0 && Sys.errno == Sys::EINTR
          end
        end
      end
      raise "worker exited; stopped remaining workers"
    end
  end
end
