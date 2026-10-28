require "socket"

# The client uses stdlib sockets; response size is learned once before warmup.
port = (ENV["PORT"]? || "3000").to_i
connections = (ENV["CONNECTIONS"]? || "200").to_i.clamp(1, 200)
seconds = (ENV["SECONDS"]? || "20").to_i.clamp(1, 20)
path = ENV["REQUEST_PATH"]? || "/"
request = "GET #{path} HTTP/1.1\r\nHost: localhost\r\n\r\n"
sockets = Array.new(connections) { TCPSocket.new("127.0.0.1", port) }
sockets[0] << request
response_size = 0
length = 0
loop do
  line = sockets[0].gets("\r\n").not_nil!
  response_size += line.bytesize
  break if line == "\r\n"
  length = line[16..].to_i if line.starts_with?("Content-Length: ")
end
sockets[0].read_fully(Bytes.new(length))
response_size += length

def drive(sockets, request, response_size, seconds)
  finished = Channel(Int64).new(sockets.size)
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
      finished.send(count)
    end
  end
  requests = 0_i64
  sockets.size.times { requests += finished.receive }
  {requests, (Time.instant - started).total_seconds}
end

# Exercise concurrent sends and reusable buffers with the same traffic as measurement.
drive(sockets, request, response_size, 2)
puts "warmup complete"
STDOUT.flush
requests, elapsed = drive(sockets, request, response_size, seconds)
sockets.each &.close
puts "connections=#{connections} duration=#{elapsed.round(3)}s requests=#{requests} req/s=#{(requests / elapsed).round(1)}"
