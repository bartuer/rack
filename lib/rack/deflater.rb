require "zlib"
require "stringio"
require "time"  # for Time.httpdate
require 'rack/utils'

module Rack
  class Deflater
    def initialize(app)
      @app = app
    end

    def deflate_type?(mime)
      return true if mime == nil
      type, sub = mime.split('/')
      return true if type == 'text'
      return false if type == 'audio' || type == 'video' || type == 'image'
      if type == 'application'
        sub = sub.split(';')[0]
        return true if ['x-javascript', 'json', 'ecmascript', 'x-python-code'].include?(sub) || sub.include?('xml')
        reject_type = ['mp4', 'octet-stream', 'ogg', 'pdf', 'rar', 'zip', 'postscript']
        return false if reject_type.include?(sub) || sub[0..1] == 'x-' || ['vnd.', 'java'].include?(sub[0..3])
      end
      return true
    end

    def call(env)
      status, headers, body = @app.call(env)

      return [status, headers, body] unless deflate_type?(headers['Content-Type'])

      headers = Utils::HeaderHash.new(headers)

      # Skip compressing empty entity body responses and responses with
      # no-transform set.
      if Utils::STATUS_WITH_NO_ENTITY_BODY.include?(status) ||
          headers['Cache-Control'].to_s =~ /\bno-transform\b/
        return [status, headers, body]
      end

      request = Request.new(env)

      encoding = Utils.select_best_encoding(%w(gzip deflate identity),
                                            request.accept_encoding)

      # Set the Vary HTTP header.
      vary = headers["Vary"].to_s.split(",").map { |v| v.strip }
      unless vary.include?("*") || vary.include?("Accept-Encoding")
        headers["Vary"] = vary.push("Accept-Encoding").join(",")
      end

      case encoding
      when "gzip"
        headers['Content-Encoding'] = "gzip"
        headers.delete('Content-Length')
        mtime = headers.key?("Last-Modified") ?
          Time.httpdate(headers["Last-Modified"]) : Time.now
        [status, headers, GzipStream.new(body, mtime)]
      when "deflate"
        headers['Content-Encoding'] = "deflate"
        headers.delete('Content-Length')
        [status, headers, DeflateStream.new(body)]
      when "identity"
        [status, headers, body]
      when nil
        message = "An acceptable encoding for the requested resource #{request.fullpath} could not be found."
        [406, {"Content-Type" => "text/plain", "Content-Length" => message.length.to_s}, [message]]
      end
    end

    class GzipStream
      def initialize(body, mtime)
        @body = body
        @mtime = mtime
      end

      def each(&block)
        @writer = block
        gzip  =::Zlib::GzipWriter.new(self)
        gzip.mtime = @mtime
        @body.each { |part|
          gzip.write(part)
          gzip.flush
        }
        @body.close if @body.respond_to?(:close)
        gzip.close
        @writer = nil
      end

      def write(data)
        @writer.call(data)
      end
    end

    class DeflateStream
      DEFLATE_ARGS = [
        Zlib::DEFAULT_COMPRESSION,
        # drop the zlib header which causes both Safari and IE to choke
        -Zlib::MAX_WBITS,
        Zlib::DEF_MEM_LEVEL,
        Zlib::DEFAULT_STRATEGY
      ]

      def initialize(body)
        @body = body
      end

      def each
        deflater = ::Zlib::Deflate.new(*DEFLATE_ARGS)
        @body.each { |part| yield deflater.deflate(part, Zlib::SYNC_FLUSH) }
        @body.close if @body.respond_to?(:close)
        yield deflater.finish
        nil
      end
    end
  end
end
