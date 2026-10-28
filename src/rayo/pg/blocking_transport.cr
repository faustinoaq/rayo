require "./poll"
require "c/netdb"
require "c/poll"
require "c/netinet/in"
require "c/netinet/tcp"

module Rayo::PG
  # Raw blocking syscalls: drain writes and reads together so a large pipeline
  # cannot deadlock when both peers fill their socket buffers.
  class BlockingTransport
    getter conn : Conn
    getter fd : Int32 = -1
    @buffer = Buf.new(65536)
    @closed = false

    def initialize(url : String, max_depth : Int32 = 16384)
      @conn = begin
        Conn.new(url, max_depth)
      rescue ex
        LibC.free(@buffer.ptr)
        raise ex
      end
      begin
        @fd = open_socket(@conn.host, @conn.port)
        until @conn.ready?
          flush
          receive unless @conn.ready?
        end
      rescue ex
        close
        raise ex
      end
    end

    private def open_socket(host : String, port : Int32) : Int32
      hints = LibC::Addrinfo.new
      hints.ai_family = LibC::AF_UNSPEC
      hints.ai_socktype = LibC::SOCK_STREAM
      res = Pointer(LibC::Addrinfo).null
      raise Error.new("cannot resolve Postgres host") unless LibC.getaddrinfo(host, port.to_s, pointerof(hints), pointerof(res)) == 0
      begin
        ai = res
        until ai.null?
          fd = LibC.socket(ai.value.ai_family, LibC::SOCK_STREAM | LibC::SOCK_CLOEXEC, 0)
          if fd >= 0
            if LibC.connect(fd, ai.value.ai_addr, ai.value.ai_addrlen) == 0
              one = 1
              LibC.setsockopt(fd, LibC::IPPROTO_TCP, LibC::TCP_NODELAY, pointerof(one).as(Void*), 4)
              return fd
            end
            LibC.close(fd)
          end
          ai = ai.value.ai_next
        end
      ensure
        LibC.freeaddrinfo(res)
      end
      raise Error.new("cannot connect to Postgres")
    end

    def query(stmt : Statement, *args, state : Int64 = 0_i64, &callback : Result, Int64 -> Nil) : Nil
      @conn.query(stmt, *args, state: state, &callback)
    end

    def query(stmt : Statement, *args, state : Pointer(T), &callback : Result, Void* -> Nil) : Nil forall T
      @conn.query(stmt, *args, state: state, &callback)
    end

    def pending : Int32
      @conn.pending
    end

    def flush : Nil
      raise Error.new("transport closed") if @closed
      loop do
        data = @conn.output
        break if data.empty?
        n = LibC.send(@fd, data.to_unsafe, data.size, LibSys::MSG_DONTWAIT | LibSys::MSG_NOSIGNAL)
        if n < 0
          next if Sys.errno == LibC::EINTR
          if Sys.errno == LibC::EAGAIN
            wait_writable
            next
          end
          @conn.lost
          raise Error.new("Postgres send failed")
        end
        @conn.on_sent(n.to_i32)
        raise Error.new("Postgres closed connection") if n == 0
      end
    end

    private def wait_writable : Nil
      event = LibPoll::Event.new
      event.fd = @fd
      event.events = (LibC::POLLIN | LibC::POLLOUT).to_i16
      loop do
        n = LibPoll.poll(pointerof(event), 1, -1)
        next if n < 0 && Sys.errno == LibC::EINTR
        raise Error.new("Postgres poll failed") if n < 0
        receive if event.revents & LibC::POLLIN != 0
        if event.revents & (LibC::POLLERR | LibC::POLLHUP | 32) != 0
          @conn.lost
          raise Error.new("Postgres socket failed")
        end
        break
      end
    end

    def receive : Nil
      raise Error.new("transport closed") if @closed
      loop do
        n = LibC.recv(@fd, @buffer.ptr, @buffer.cap, 0)
        next if n < 0 && Sys.errno == LibC::EINTR
        if n <= 0
          @conn.lost
          raise Error.new("Postgres receive failed or EOF")
        end
        @conn.on_data(@buffer.ptr, n.to_i32)
        break
      end
    end

    def drain : Nil
      loop do
        @conn.on_data(Pointer(UInt8).null, 0)
        flush
        break if pending == 0
        receive
      end
    end

    def close : Nil
      return if @closed
      raise Error.new("cannot close during callback") if @conn.dispatching?
      begin
        @conn.close
      ensure
        @closed = true
        LibC.close(@fd) if @fd >= 0
        @fd = -1
        LibC.free(@buffer.ptr)
      end
    end
  end
end
