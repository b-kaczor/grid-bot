# frozen_string_literal: true

# Minimal Redis mock for specs that need Redis without a live server.
# Supports: get/set (with nx), del, hset/hgetall/hincrby, pipelined.
class MockRedis
  def initialize
    @store = {}
    @hashes = {}
  end

  def set(key, value, **options)
    return false if options[:nx] && @store.key?(key)

    @store[key] = value.to_s
    true
  end

  def get(key) = @store[key]

  def del(*keys)
    keys.each do |k|
      @store.delete(k)
      @hashes.delete(k)
    end
  end

  def hset(key, *args)
    @hashes[key] ||= {}
    if args.length == 2
      @hashes[key][args[0].to_s] = args[1].to_s
    else
      args.each_slice(2) { |f, v| @hashes[key][f.to_s] = v.to_s }
    end
  end

  def hgetall(key) = @hashes[key] || {}

  def hincrby(key, field, increment)
    @hashes[key] ||= {}
    @hashes[key][field.to_s] = ((@hashes[key][field.to_s] || '0').to_i + increment).to_s
  end

  def pipelined
    yield self
  end
end
