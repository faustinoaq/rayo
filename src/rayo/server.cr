require "./context"
require "./uring"

module Rayo::Server
  # Connection buffers go back to the allocator whenever they are empty, so an idle
  # keep-alive connection holds no buffer memory (on a 2 GB box this decides how many
  # connections fit). Buffers are allocated on first use and grow as needed.
  SHRINK_ABOVE = 0

  # Buffers and Context are retained per slot and reused even after a peer disconnects.
  # In-flight output is immutable; new responses accumulate in next_output. The
  # pipelining buffers start empty and grow only when a client pipelines.
  class Connection
    getter input = Buf.new(0)
    getter backlog = Buf.new(0)
    property output = Buf.new(0)
    property next_output = Buf.new(0)
    getter context : Context
    property gen = 0_u16
    property open = false
    property busy = false
    property closing = false
    property eof = false
    property sending = false
    property retired = false
    property shutting_down = false
    property sent = 0
    property consumed = 0

    def initialize(id : Int32)
      @context = Context.new(id)
    end

    def reset : Nil
      @gen &+= 1
      @open = false
      @busy = false
      @closing = false
      @eof = false
      @sending = false
      @retired = false
      @shutting_down = false
      @sent = @consumed = 0
      @input.clear
      @backlog.clear
      @output.clear
      @next_output.clear
      shrink
    end

    def shrink : Nil
      @input.shrink(SHRINK_ABOVE, 0)
      @backlog.shrink(SHRINK_ABOVE, 0)
      @output.shrink(SHRINK_ABOVE, 0)
      @next_output.shrink(SHRINK_ABOVE, 0)
      @context.output.shrink(SHRINK_ABOVE, 0)
    end
  end

  @@conns = [] of Connection?
  @@app : App? = nil

  def self.init(app : App, n : Int32) : Nil
    @@app = app
    @@conns = Array(Connection?).new(n, nil)
  end

  def self.conn(id : Int32) : Connection
    @@conns[id] ||= Connection.new(id)
  end

  def self.on_data(id : Int32, p : UInt8*, n : Int32) : Nil
    c = conn(id)
    return if c.closing
    b = c.busy ? c.backlog : c.input
    if b.len.to_i64 + n > HTTP::MAX_BODY + HTTP::MAX_HEADER
      Uring.close(id)
      return
    end
    b.write(p, n)
    process(id) unless c.busy
  end

  def self.on_eof(id : Int32) : Nil
    c = conn(id)
    c.eof = true
    c.closing = true unless c.busy
    flush(id)
  end

  def self.process(id : Int32) : Nil
    c = conn(id)
    off = 0
    req = HTTP::Request.new
    while off < c.input.len && !c.busy && !c.closing
      n = HTTP.parse(c.input.ptr + off, c.input.len - off, pointerof(req))
      break if n == HTTP::NEED_MORE
      if n == HTTP::BAD
        req = HTTP::Request.new
        req.close = true
        c.context.reset(req)
        c.context.status(400)
        emit(id)
        return unless c.open
        c.closing = true
        break
      end
      c.context.reset(req)
      c.consumed = off + n
      c.busy = true
      begin
        @@app.not_nil!.dispatch(c.context)
      rescue
        c.context.cancel_defer
        c.context.output.clear
        c.context.status(500)
      end
      if c.context.deferred
        break
      end
      c.busy = false
      emit(id)
      return unless c.open
      off += n
      c.closing = req.close
    end
    unless c.busy
      c.input.ptr.move_from(c.input.ptr + off, c.input.len - off) if off > 0
      c.input.len -= off
      c.input.shrink(SHRINK_ABOVE, 0)
      c.closing = true if c.eof
    end
    flush(id)
  end

  def self.emit(id : Int32) : Nil
    c = conn(id)
    ctx = c.context
    begin
      @@app.not_nil!.after_response(ctx)
      @@app.not_nil!.compress_response(ctx)
    rescue
      ctx.output.clear
      ctx.status(500)
    end
    target = c.sending ? c.next_output : c.output
    HTTP.response(target, ctx.code, ctx.output, ctx.headers, ctx.content_type, ctx.request.close, ctx.method == HTTP::Method::HEAD)
    if ctx.output.cap > SHRINK_ABOVE
      ctx.output.clear
      ctx.output.shrink(SHRINK_ABOVE, 0)
    end
    Uring.close(id) if target.len > 4 * HTTP::MAX_BODY
  end

  def self.finish(id : Int32) : Nil
    c = conn(id)
    emit(id)
    return unless c.open
    c.busy = false
    c.closing = c.context.request.close
    c.input.ptr.move_from(c.input.ptr + c.consumed, c.input.len - c.consumed)
    c.input.len -= c.consumed
    c.input.write(c.backlog.ptr, c.backlog.len)
    c.backlog.clear
    c.backlog.shrink(SHRINK_ABOVE, 0)
    c.closing ? flush(id) : process(id)
  end

  def self.flush(id : Int32) : Nil
    c = conn(id)
    return if c.sending || !c.open
    if c.output.len > 0
      c.sending = true
      c.sent = 0
      Uring.send(id, c.output.ptr, c.output.len)
    elsif c.closing && !c.busy
      Uring.close(id)
    end
  end

  def self.on_sent(id : Int32, n : Int32) : Nil
    c = conn(id)
    c.sending = false
    if c.retired
      Uring.release(id) unless c.shutting_down
      return
    end
    if n <= 0
      Uring.close(id)
      return
    end
    c.sent += n
    if c.sent < c.output.len
      c.sending = true
      Uring.send(id, c.output.ptr + c.sent, c.output.len - c.sent)
      return
    end
    c.output.clear
    c.output.shrink(SHRINK_ABOVE, 0)
    c.output, c.next_output = c.next_output, c.output
    flush(id)
  end
end
