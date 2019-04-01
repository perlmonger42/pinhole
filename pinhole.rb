#!/usr/bin/env ruby
# vim: filetype=ruby
require 'httparty'
require 'json'
require 'active_support/inflector'
require 'ffaker'

# $Verbose == 0: no trace output will be printed
# $Verbose >= 1: print request verbs and URI's (e.g., GET http://sample.com/foo)
# $Verbose >= 2: also print bodies and response codes
# $Verbose >  2: also print request headers, and show request failure responses
$Verbose = 1


class GenericError < StandardError
  attr_reader :hash
  def initialize(**hash)
    @hash = hash
  end

  def to_s
    response = @hash[:response]
    # puts "ERROR: #{response.inspect}"
    if response&.parsed_response
      resp = response.parsed_response
      hash = String === resp ? JSON.parse(resp) : resp
    end
    if hash
      what = hash.dig('errors', 0, 'detail') ||
        hash.dig('errors', 0, 'title')
    end
    (what || hash || resp || @hash).to_s
  end
end

def show(response)
  puts "ERROR" if response.code < 200 || 300 <= response.code
  puts "response.code: #{response.code}"
  puts "response.message: #{response.message}"
  puts "response.headers: #{response.headers.inspect}"
  puts "response.body: #{response.body}"
  puts
  response
end

def Oops(**hash)
  GenericError.new(hash)
end

class Blacksmith
  include HTTParty
  base_uri ENV['REACTOR_API_URL']

  def initialize
    required = %w(REACTOR_API_URL REACTOR_API_KEY REACTOR_API_TOKEN REACTOR_ORG_ID)
    if required.any? { |k| ENV[k].to_s.empty? }
      msg = "Your environment has not been set up.\n" +
        "You have at least one missing value:\n"
      required.each { |k| msg += "\n  #{k} is #{ENV[k].inspect}" }
      raise Oops(msg: msg)
    end

    @base_uri = ENV['REACTOR_API_URL']
    @default_headers = {
      'Accept' => 'application/vnd.api+json;revision=1',
      'Content-Type' => 'application/vnd.api+json',
      'X-Api-Key' => ENV['REACTOR_API_KEY'],
      'Authorization' => "Bearer #{ENV['REACTOR_API_TOKEN']}"
    }
  end

  def to_s
    @base_uri
  end

  def headers(new_headers)
    all_headers = @default_headers.merge(new_headers)
  end

  # verb is a symbol in the set { :get, :post, :patch, :put, :delete }
  # options keys are in the set { :headers, :body, :query, ... }
  # (there are many other option keys supported; see
  # https://github.com/jnunemaker/httparty/blob/master/lib/httparty/request.rb)
  def perform_request(verb, uri, options)
    puts "#{verb.to_s.upcase} #{uri}" if $Verbose > 0
    o = options.dup
    o[:headers] = @default_headers.merge(options.fetch(:headers, {}))
    puts "  headers: #{o[:headers]}" if $Verbose > 2 && o[:headers]
    if o[:body]
      o[:body] = o[:body].to_json unless String === o[:body]
      puts "  body: #{JSON.pretty_generate(JSON.parse(o[:body]))}" if $Verbose > 1
    end
    response = self.class.send(verb, uri, **o)
    puts "#{response.code} #{response.message}" if $Verbose > 1
    show(response) if $Verbose > 2 && (response.code < 200 || 300 <= response.code)
    construct_entities verb.to_s.upcase, uri, response
  end

  def get(uri, **options)
    perform_request(:get, uri, options)
  end

  #def old_get(uri, headers:{})
  #  h = @default_headers.merge(headers)
  #  puts "GET #{uri}" if $Verbose > 0
  #  puts "  headers: #{h}" if $Verbose > 2
  #  # puts "  body: #{JSON.pretty_generate(JSON.parse(body))}" if $Verbose > 1
  #  response = self.class.get(uri, headers: h)
  #  puts "#{response.code} #{response.message}" if $Verbose > 1
  #  show(response) if $Verbose > 2 && (response.code < 200 || 300 <= response.code)
  #  construct_entities :GET, uri, response
  #end

  def post(uri, **options)
    perform_request(:post, uri, options)
  end

  #def old_post(uri, headers: {}, body: {})
  #  h = @default_headers.merge(headers)
  #  body = body.to_json unless String === body
  #  puts "POST #{uri}" if $Verbose > 0
  #  puts "  headers: #{h}" if $Verbose > 2
  #  puts "  body: #{JSON.pretty_generate(JSON.parse(body))}" if $Verbose > 1
  #  response =self.class.post(uri, headers: h, body: body)
  #  puts "#{response.code} #{response.message}" if $Verbose > 1
  #  construct_entities :POST, uri, response
  #  perform_request(:get, uri, headers: h)
  #end

  def delete(uri, **options)
    perform_request(:delete, uri, options)
  end

  # Construct a Blacksmith Entity from a Plain Old Ruby Object (i.e., a parsed
  # JSON string)
  def poro_to_entity(data)
    data['type'].classify.constantize.new(self, data)
  rescue => error
    raise Oops(
      msg: 'Cannot construct Entity from data',
      data: data,
      error: error,
    )
  end

  def construct_entities(verb, request_uri, response)
    return nil if response.code == 204
    if 200 <= response.code && response.code < 300
      if response.headers['content-type'] =~ %r{^application/vnd.api\+json}
#require "json-api-vanilla"
#doc = JSON::Api::Vanilla.parse(response.body)
#pp(doc)
#require 'pry'; binding.pry;
        data = JSON.parse(response.body)['data']
        return poro_to_entity(data) if Hash === data
        return data.map {|item| poro_to_entity(item) } if Array === data
        raise Oops(
          msg: %q(invalid payload['data'] type),
          source: "#{self.class}##{__method__} from #{verb} #{request_uri}",
          response: response,
        )
      end
    end
    raise Oops(
      verb: verb,
      path: request_uri,
      response: response,
      source: "#{self.class}##{__method__}",
    )
  end

  def find(klass, **options)
    get(klass.search_uri(**options))
  end
end

# base class for Blacksmith objects
class Entity
  attr_reader :id

  # Initialize an entity from the JSONAPI representation of its data
  def initialize(blacksmith_server, data)
    @server = blacksmith_server
    data['type'].classify == self.class.name or raise Oops(
      source: "#{self.class}##{__callee__}",
      error: "Cannot create #{self.class} from data type #{data['type'].inspect}"
    )
    @id = data['id']
    data['attributes'].each { |k, v| self.instance_variable_set("@#{k}", v) }
  rescue => error
    raise Oops(
      msg: "Cannot initialize #{self.class} instance from data",
      data: data,
      error: error,
    )
  end

  def to_s
    "#{@id} #{@name.inspect}"
  end
end

class Org < Entity
  attr_reader :name
  COMPANY_ID = nil

  def initialize(blacksmith_server, org_id, company_id: id)
    @server = blacksmith_server
    @id = org_id
    @company_id = company_id
  end

  def company_id
    @company_id ||= COMPANY_ID || @company&.id
    if @company_id
      puts "Using an existing company ID on #{blacksmith}"
      puts "  #{company_id || company.id}"
      return @company_id
    end
    company.id
  end

  def company
    return @company if @company
    puts "Looking up a company for #{blacksmith} #{@id}"
    @company = blacksmith.find(Company)[0]
    raise "No company found for #{ORG_ID}" unless @company
    puts "  #{company.id}"
    @company
  end
end

class Company < Entity
  attr_reader :name

  # Return the URI to search for a company by org_id (defaults to
  # $REACTOR_ORG_ID)
  def self.search_uri(org_id: nil)
    org_id = ENV['REACTOR_ORG_ID'] if org_id.to_s.empty?
    "/companies?filter[org_id]=EQ%20#{org_id}"
  end

  def delete
    @server.delete("/companies/#{@id}")
  end

  def properties
    return @properties if @properties
    @properties ||= @server.get("/companies/#{@id}/properties")
  end

  def new_faked_property
    property_name = FFaker::Company.name
    domain = FFaker::Internet.domain_name
    @server.post("/companies/#{@id}/properties", body: {
      data: {
        type: 'properties',
        attributes: {
          name: property_name,
          domains: ["#{FFaker::Internet::domain_word}.#{domain}"],
          platform: 'web',
        },
      }
    })
  end
end

class Property < Entity
  attr_reader :name

  # Return the URI to search for a property by property_id
  def self.search_uri(id:)
    "/properties/#{id}"
  end

  def delete
    @server.delete("/properties/#{@id}")
  end

  def new_faked_adapter
    Adapter.new_faked_adapter(@server, @id)
  end

  def new_faked_adapter
    Library.new_faked_library(@server, @id)
  end
end

class Adapter < Entity
  attr_reader :name

  # Return the URI to search for a property by property_id
  def self.search_uri(id:)
    "/adapters/#{id}"
  end

  def self.new_faked_adapter(blacksmith_server, property_id:)
    adapter_name = "#{FFaker::Product.brand} #{FFaker::Product.model} Adapter"
    #host = "#{FFaker::Internet::domain_word}.#{FFaker::Internet.domain_name}"
    host = "adobeio.com"
    payload = {
      data: {
        type: 'adapters',
        attributes: {
          name: adapter_name,
          type_of: 'sftp',
          username: FFaker::Name.name,
          host: host,
          path: FFaker::Internet.slug,
          port: 22,
          encrypted_private_key: "-----BEGIN PGP MESSAGE-----\n\nHQIMAwB8kNQ7jtk8AQ/+IPE+jteweLyNgdkzkBWN4c+wpRfTP9ionSywdWzZsRZ2\ngpIHLidqCgM+iRw0CgbAKhdAmA1wVyWP4HCa0eJuNCVwj+NqJlWW8qWxCWeZi2KC\nhqsoaB5+xIbS3Jwt8S4Na+DgvyjSj88sALvG9Y/xqNexRvcuvv0KKFoVYPOeW/w9\n+6x+vUmZFrTWMaNtKH6X9kifo5l+05d3XngPLfml4cKzWmO1f3FEvTX0O4nJurQ7\nNc27dt2XAO5Y8bqCClQ6AHOFVrkKnTifHF79A3AhCB5E9wMY4FJ/EReZ6Uk0ixOn\n76XeGbkl1jidajM5G/gylwEwOXN8CVy5DQyvxGulhsaaqtri7GZxQC5HUTETIHwO\nxThAttH22uaBjhMmYiCvPzSL4Z9UNFZeGPfb17k5E1kauprR2ItUJX86+Cid/FnR\nW7QN/8J4Jnf6Ggp90VujV0uIvdyLYq3T0xe9WZmONJaQ5bDYDv5ZfkcapOvXw4zr\nxrL1vrpZ5Qfu8oLQ19JOT2o7e3p8Kh7lDPIL7RH2bYesinLJ7wdopmkpj4/4gpHK\njzlWalZd75PEsttsUJ+ODVSOXG7iVhx9EvkZagUo0oeZ3oY1Jy5oik/gvVp28wDO\n8T1uYK/jeCSiuslxCYxth8a+5Wgiy8Jw1vHCRudsNgU1x2zYuOJetJS14Z/CTETS\nTgGPh0J6fQEvzZTM6AEJpRs+cVZV1hnTspyo2S5wv/SdrbqMkVHhs8rlq/0PWpSB\nLhLNlh8kLPR0KOG0V79GEO20At0HL/yGny/GKrTyAw==\n=oRpa\n-----END PGP MESSAGE-----\n",
        },
      }
    }
    blacksmith_server.post("/properties/#{property_id}/adapters", body: payload)
  end

  def new_faked_environment
    Adapter.new_faked_environment(@server, property_id, @id)
  end
end

class Environment < Entity
  attr_reader :name

  # Return the URI to search for a property by property_id
  def self.search_uri(id:)
    "/environments/#{id}"
  end

  def self.new_faked_environment(blacksmith_server, property_id:, adapter_id:)
    environment_name = "#{FFaker::Animal.common_name} Environment"
    payload = {
      data: {
        type: 'environments',
        attributes: {
          name: environment_name,
          stage: 'development',
          path: '/foo/bar',
        },
        relationships: { adapter: { data: { type: 'adapters', id: adapter_id } } }
      }
    }
    r = blacksmith_server.post("/properties/#{property_id}/environments", body: payload)
    r
  end
end

class Library < Entity
  attr_reader :name

  # Return the URI to search for a library by library_id
  def self.search_uri(id:)
    "/libraries/#{id}"
  end

  # environment_id is optional; if present, it will be linked to the library
  def self.new_faked_library(blacksmith_server, property_id:, environment_id: nil)
    library_name = "#{FFaker::Product.model} #{FFaker::Animal.common_name} Library"
    payload = {
      data: {
        type: 'libraries',
        attributes: { name: library_name },
      }
    }
    if environment_id
      payload[:data][:relationships] = {
        environment: { data: { id: environment_id, type: 'environments' } }
      }
    end
    blacksmith_server.post("/properties/#{property_id}/libraries", body: payload)
  end

  def build
    @server.post("/libraries/#{@id}/builds")
  end
end

class Build < Entity
  # Return the URI to search for a build by build_id
  def self.search_uri(id:)
    "/builds/#{id}"
  end
end
