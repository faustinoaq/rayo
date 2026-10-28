require "./sys"
require "./buf"

module Rayo::HTTP
  lib LibDate
    fun strftime(dst : UInt8*, size : LibC::SizeT, format : UInt8*, tm : LibC::Tm*) : LibC::SizeT
  end

  enum Method
    GET
    POST
    PUT
    PATCH
    DELETE
    HEAD
    OPTIONS
    OTHER
  end

  METHOD_NAMES = {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "OTHER"}

  NEED_MORE  =     0
  BAD        =    -1
  MAX_HEADER = 16384
  MAX_BODY   = 1 << 20

  struct Request
    property method = Method::OTHER
    property path = Bytes.empty
    property query = Bytes.empty
    property headers = Bytes.empty
    property body = Bytes.empty
    property close = false

    def header(name : String) : Bytes
      HTTP.field(headers, name, 13_u8)
    end
  end

  # ASCII comparison without constructing temporary strings.
  def self.equal(a : Bytes, b : String, fold = false) : Bool
    return false unless a.size == b.bytesize
    a.size.times do |i|
      x, y = a[i], b.to_unsafe[i]
      x |= 32_u8 if fold && x >= 65 && x <= 90
      y |= 32_u8 if fold && y >= 65 && y <= 90
      return false if x != y
    end
    true
  end

  def self.field(data : Bytes, name : String, separator = 38_u8) : Bytes
    i = 0
    while i < data.size
      e = i
      while e < data.size && data[e] != separator
        e &+= 1
      end
      k = i
      delim = separator == 13 ? 58_u8 : 61_u8
      while k < e && data[k] != delim
        k &+= 1
      end
      if k < e && equal(data[i, k - i], name, separator == 13)
        b = k + 1
        while b < e && (data[b] == 32 || data[b] == 9)
          b &+= 1
        end
        while e > b && (data[e - 1] == 32 || data[e - 1] == 9)
          e &-= 1
        end
        return data[b, e - b]
      end
      i = e + (separator == 13 ? 2 : 1)
    end
    Bytes.empty
  end

  def self.parse(p : UInt8*, n : Int32, result : Request*) : Int32
    he = LibSys.memmem(p, n, "\r\n\r\n".to_unsafe, 4).as(UInt8*)
    return n > MAX_HEADER ? BAD : NEED_MORE if he.null?
    hlen = (he - p).to_i32 + 4
    return BAD if hlen > MAX_HEADER
    le = LibSys.memmem(p, hlen, "\r\n".to_unsafe, 2).as(UInt8*)
    sp = LibC.memchr(p, 32, le - p).as(UInt8*)
    return BAD if sp.null?
    r = Request.new
    m = Bytes.new(p, (sp - p).to_i32)
    return BAD if m.empty? || m.any? { |c| c <= 32 || c >= 127 }
    {% for method in %w(GET POST PUT PATCH DELETE HEAD OPTIONS) %}
      r.method = Method::{{method.id}} if equal(m, {{method}})
    {% end %}
    target = sp + 1
    sp = LibC.memchr(target, 32, le - target).as(UInt8*)
    return BAD if sp.null? || target == sp || target.value != 47
    version = Bytes.new(sp + 1, (le - sp - 1).to_i32)
    return BAD unless equal(version, "HTTP/1.1") || equal(version, "HTTP/1.0")
    r.close = equal(version, "HTTP/1.0")
    qm = LibC.memchr(target, 63, sp - target).as(UInt8*)
    r.path = Bytes.new(target, ((qm.null? ? sp : qm) - target).to_i32)
    r.query = Bytes.new(qm + 1, (sp - qm - 1).to_i32) unless qm.null?
    r.headers = Bytes.new(le + 2, (he - le).to_i32)
    target_bytes = Bytes.new(target, (sp - target).to_i32)
    return BAD if target_bytes.any? { |c| c <= 32 || c == 127 }
    connection_close = false
    q = le + 2
    length = -1
    while q < he
      e = LibSys.memmem(q, (he - q + 2), "\r\n".to_unsafe, 2).as(UInt8*)
      return BAD if e.null?
      colon = LibC.memchr(q, 58, e - q).as(UInt8*)
      return BAD if colon.null? || colon == q
      Bytes.new(q, (colon - q).to_i32).each do |v|
        return BAD unless (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || "!#$%&'*+-.^_`|~".to_slice.includes?(v)
      end
      name = Bytes.new(q, (colon - q).to_i32)
      b = colon + 1
      while b < e && (b.value == 32 || b.value == 9)
        b += 1
      end
      z = e
      while z > b && (z[-1] == 32 || z[-1] == 9)
        z -= 1
      end
      value = Bytes.new(b, (z - b).to_i32)
      value.each { |c| return BAD if (c < 32 && c != 9) || c == 127 }
      if equal(name, "content-length", true)
        return BAD if length >= 0 || value.empty?
        length = 0
        value.each do |c|
          return BAD unless c >= 48 && c <= 57
          length = length &* 10 &+ (c - 48)
          return BAD if length > MAX_BODY
        end
      elsif equal(name, "transfer-encoding", true)
        return BAD # No ambiguous framing or chunked request bodies in 0.1.
      elsif equal(name, "connection", true)
        # Connection is a comma separated token list.
        i = 0
        while i < value.size
          j = i
          while j < value.size && value[j] != 44
            j += 1
          end
          a, zt = i, j
          while a < zt && (value[a] == 32 || value[a] == 9)
            a += 1
          end
          while zt > a && (value[zt - 1] == 32 || value[zt - 1] == 9)
            zt -= 1
          end
          token = value[a, zt - a]
          connection_close = true if equal(token, "close", true)
          r.close = false if equal(token, "keep-alive", true)
          i = j + 1
        end
      end
      q = e + 2
    end
    r.close = true if connection_close
    length = 0 if length < 0
    return NEED_MORE if n < hlen + length
    r.body = Bytes.new(p + hlen, length)
    result.value = r
    hlen + length
  end

  STATUS = {203 => "203 Non-Authoritative Information", 205 => "205 Reset Content", 206 => "206 Partial Content", 303 => "303 See Other", 307 => "307 Temporary Redirect", 308 => "308 Permanent Redirect", 406 => "406 Not Acceptable", 408 => "408 Request Timeout", 409 => "409 Conflict", 410 => "410 Gone", 412 => "412 Precondition Failed", 414 => "414 URI Too Long", 415 => "415 Unsupported Media Type", 416 => "416 Range Not Satisfiable", 417 => "417 Expectation Failed", 418 => "418 I'm a teapot", 421 => "421 Misdirected Request", 422 => "422 Unprocessable Content", 423 => "423 Locked", 424 => "424 Failed Dependency", 425 => "425 Too Early", 426 => "426 Upgrade Required", 428 => "428 Precondition Required", 429 => "429 Too Many Requests", 431 => "431 Request Header Fields Too Large", 451 => "451 Unavailable For Legal Reasons", 501 => "501 Not Implemented", 502 => "502 Bad Gateway", 504 => "504 Gateway Timeout", 505 => "505 HTTP Version Not Supported", 507 => "507 Insufficient Storage", 511 => "511 Network Authentication Required", 200 => "200 OK", 201 => "201 Created", 202 => "202 Accepted", 204 => "204 No Content", 301 => "301 Moved Permanently", 302 => "302 Found", 304 => "304 Not Modified", 400 => "400 Bad Request", 401 => "401 Unauthorized", 403 => "403 Forbidden", 404 => "404 Not Found", 405 => "405 Method Not Allowed", 411 => "411 Length Required", 413 => "413 Content Too Large", 500 => "500 Internal Server Error", 503 => "503 Service Unavailable"}
  @@date = Buf.new(64)
  @@second = -1_i64

  def self.date : Buf
    sec = Sys.now_ns(Sys::CLOCK_REALTIME_COARSE) // 1_000_000_000
    if sec != @@second
      @@second = sec
      tm = uninitialized LibC::Tm
      LibC.gmtime_r(pointerof(sec), pointerof(tm))
      @@date.len = LibDate.strftime(@@date.ptr, 64, "%a, %d %b %Y %H:%M:%S GMT", pointerof(tm)).to_i32
    end
    @@date
  end

  def self.response(dst : Buf, status : Int32, body : Buf, headers : Buf, type : String | Bytes, close : Bool, head : Bool) : Nil
    dst << "HTTP/1.1 " << (STATUS[status]? || "500 Internal Server Error") << "\r\nDate: "
    d = date
    dst.write(d.ptr, d.len)
    dst << "\r\nContent-Length: " << (status == 204 || status == 304 ? 0 : body.len) << "\r\nContent-Type: "
    bytes = type.is_a?(String) ? type.to_slice : type
    dst.write(bytes.to_unsafe, bytes.size)
    dst << "\r\n"
    dst << "Connection: close\r\n" if close
    dst.write(headers.ptr, headers.len)
    dst << "\r\n"
    dst.write(body.ptr, body.len) unless head || status == 204 || status == 304
  end
end
