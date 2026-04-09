require "minitest/autorun"
require "fileutils"
require "rack/mock"
require "tmpdir"

require_relative "../config/environment"

class FakeConnection
  attr_reader :queries

  def initialize(*responses)
    @responses = responses
    @queries = []
  end

  def exec(sql)
    @queries << sql
    @responses.shift || []
  end
end
