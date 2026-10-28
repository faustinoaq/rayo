require "socket"

# Run against examples/hello.cr. The client uses stdlib sockets; the server does not.
port = (ENV["PORT"]? || "3000").to_i
connections = 200
seconds = 20
request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
response_size = "HTTP/1.1 200 OK\r\nDate: Wed, 28 Oct 2026 00:00:00 GMT\r\nContent-Length: 13\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHello, world!".bytesize
sockets = Array.new(connections) { TCPSocket.new("127.0.0.1", port) }
warmup = Bytes.new(response_size)
sockets.each do |socket|
  32.times do
    socket << request
    socket.read_fully(warmup)
  end
end
finished = Channel(Int64).new(connections)
started = Time.instant
stop = started + seconds.seconds
sockets.each do |socket|
  spawn do
    count = 0_i64
    buffer = Bytes.new(response_size)
    while Time.instant < stop
      socket << request
      socket.read_fully(buffer)
      count += 1
    end
    socket.close
    finished.send(count)
  end
end
requests = 0_i64
connections.times { requests += finished.receive }
elapsed = (Time.instant - started).total_seconds
puts "connections=#{connections} duration=#{elapsed.round(3)}s requests=#{requests} req/s=#{(requests / elapsed).round(1)}"
