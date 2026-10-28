require "../context"
require "../json"

class Rayo::Context
  def json(**fields) : Nil
    @content_type = "application/json"
    json_writer.value(fields)
  end

  def json(&) : Nil
    @content_type = "application/json"
    writer = json_writer
    yield writer
  end

  def json_array(enumerable, &) : Nil
    json { |writer| writer.array(enumerable) { |item| yield item } }
  end

  def json_body : JSON::Reader
    JSON::Reader.new(body)
  end
end
