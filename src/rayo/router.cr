require "./http"

module Rayo
  class Router
    MAX_PARAMS = 32
    alias Handler = Proc(Context, Nil)

    class Node
      getter children = Hash(String, Node).new
      property parameter : Node? = nil
      property wildcard : Node? = nil
      property name = ""
      getter handlers = StaticArray(Handler?, 8).new(nil)
    end

    getter root = Node.new

    def add(method : HTTP::Method, path : String, handler : Handler) : Nil
      raise ArgumentError.new("route must start with /") unless path.starts_with?('/')
      node = @root
      parts = path[1..].split('/')
      count = 0
      parts.each_with_index do |part, i|
        if part.starts_with?(':')
          raise ArgumentError.new("empty parameter") if part.size == 1
          count += 1
          child = node.parameter || Node.new
          raise ArgumentError.new("conflicting parameter names") if child.name != "" && child.name != part[1..]
          child.name = part[1..]
          node.parameter = child
          node = child
        elsif part.starts_with?('*')
          raise ArgumentError.new("wildcard must be trailing") unless i == parts.size - 1
          count += 1
          child = node.wildcard || Node.new
          child.name = part.size == 1 ? "*" : part[1..]
          node.wildcard = child
          node = child
        else
          node = node.children[part] ||= Node.new
        end
      end
      raise ArgumentError.new("too many route parameters") if count > MAX_PARAMS
      raise ArgumentError.new("duplicate route") if node.handlers[method.value]
      node.handlers[method.value] = handler
    end

    # Static segments win, then parameters, then the trailing wildcard. Failed branches
    # restore the capture count, so backtracking never leaves stale parameters behind.
    def match(node : Node, path : Bytes, offset : Int32, ctx : Context) : Node?
      e = offset
      while e < path.size && path[e] != 47
        e &+= 1
      end
      segment = path[offset, e - offset]
      last = e == path.size
      node.children.each do |name, child|
        next unless HTTP.equal(segment, name)
        if last
          return child if child.handlers.any?
        elsif found = match(child, path, e + 1, ctx)
          return found
        end
      end
      saved = ctx.param_count
      if child = node.parameter
        unless segment.empty?
          ctx.capture(child.name, segment)
          if last
            return child if child.handlers.any?
          elsif found = match(child, path, e + 1, ctx)
            return found
          end
          ctx.param_count = saved
        end
      end
      if child = node.wildcard
        ctx.capture(child.name, path[offset, path.size - offset])
        return child
      end
      nil
    end

    def dispatch(ctx : Context) : Nil
      node = match(@root, ctx.path, 1, ctx)
      unless node
        ctx.status(404)
        return
      end
      if handler = node.handlers[ctx.method.value]
        handler.call(ctx)
      else
        ctx.status(405)
        ctx.headers << "Allow: "
        first = true
        node.handlers.each_with_index do |entry, i|
          next unless entry
          ctx.headers << ", " unless first
          ctx.headers << HTTP::METHOD_NAMES[i]
          first = false
        end
        ctx.headers << "\r\n"
      end
    end
  end
end
