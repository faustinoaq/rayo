require "./sys"
require "./http"
require "./router"
require "./context"
require "./server"
require "./context/json"
require "./context/db"

module Rayo
  class App
    getter router = Router.new
    @before = [] of Router::Handler
    @after = [] of Router::Handler
    @worker_start = [] of Proc(Int32, Nil)

    def on_worker_start(&block : Int32 -> Nil) : Nil
      @worker_start << block
    end

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

    private def worker(host : String, ports : Array(Int32), workers : Int32, database : String?, pool : Int32, index : Int32) : NoReturn
      reset_signals
      fds = [] of Int32
      begin
        ports.each { |port| fds << listen(host, port) }
      rescue ex
        fds.each { |fd| LibC.close(fd) }
        raise ex
      end
      unless Uring.setup(fds.to_unsafe, fds.size, Sys.raise_nofile, workers)
        fds.each { |fd| LibC.close(fd) }
        raise "io_uring setup failed (Linux 6.1+ required)"
      end
      Server.init(self, Uring.capacity)
      Server.database = PG::WorkerPool.new(database, pool) if database
      @worker_start.each &.call(index)
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

    def run(host = "0.0.0.0", port = 3000, workers = Sys.ncpu, database : String? = ENV["DATABASE_URL"]?, pool : Int32 = 4, ports : Array(Int32)? = nil) : NoReturn
      raise ArgumentError.new("workers must be positive") if workers < 1
      raise ArgumentError.new("invalid port") unless 0 <= port <= 65535
      raise ArgumentError.new("pool size must be positive") if pool < 1
      listeners = ports || [port]
      raise ArgumentError.new("ports must not be empty") if listeners.empty?
      listeners.each { |value| raise ArgumentError.new("invalid port") unless 0 <= value <= 65535 }
      worker(host, listeners, 1, database, pool, 0) if workers == 1
      {% unless flag?(:without_mt) %}
        raise "multiple workers require -Dwithout_mt: Crystal runtime threads cannot survive fork; rebuild with --release -Dwithout_mt (optionally -Dgc_none)"
      {% end %}
      reset_signals
      pids = [] of Int32
      begin
        workers.times do |index|
          parent = LibC.getpid
          pid = LibC.fork
          raise "fork failed" if pid < 0
          if pid == 0
            LibSys.prctl(1, 15_u64)
            LibC._exit(1) if LibC.getppid != parent
            begin
              worker(host, listeners, workers, database, pool, index)
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
