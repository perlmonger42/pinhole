#!/usr/bin/env ruby
# vim: filetype=ruby
require 'httparty'
require 'json'
require 'active_support/inflector'
require 'ffaker'

# $Verbose == 0: no trace output will be printed
# $Verbose >= 1: print entity ID's as entities are created
# $Verbose >= 2: print request verbs and URI's (e.g., GET http://sample.com/foo)
#                also, print error response codes
# $Verbose >= 3: also print request bodies, response bodies, and response codes
# $Verbose >= 4: also print request headers and response headers
$Verbose = 2

def id_to_type(id)
  return 'adapters' if id =~ /^AD/
  return 'audit_events' if id =~ /^AE/
  return 'builds' if id =~ /^BL/
  return 'callbacks' if id =~ /^CB/
  return 'companies' if id =~ /^CO/
  return 'data_elements' if id =~ /^DE/
  return 'properties' if id =~ /^PR/
  return 'environments' if id =~ /^EN/
  return 'extension_packages' if id =~ /^EP/
  return 'extensions' if id =~ /^EX/
  return 'libraries' if id =~ /^LB/
  return 'users' if id =~ /^UR/
  return 'rule_components' if id =~ /^RC/
  return 'rules' if id =~ /^RL/
  raise "id_to_type: cannot indentify type of #{id}"
end

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

class HtmlError < GenericError
end

# def show(response)
#   puts "ERROR" if response.code < 200 || 300 <= response.code
#   puts "response.code: #{response.code}"
#   puts "response.message: #{response.message}"
#   puts "response.headers: #{response.headers.inspect}"
#   puts "response.body: #{response.body}"
#   puts
#   response
# end

def raise_html_error(response, errors)
  if $Verbose >= 2
    errors = *errors
    errors.each do |error|
      print "  #{error['meta']['request_id']}" if error&.dig('meta', 'request_id')
      puts "  «#{error['title'] || 'unknown error'}» #{error['detail']}"
    end
  end
  raise HtmlError.new(response: response)
end

class PinholeError < GenericError
end

def Oops(**hash)
  caller_infos = caller.first.split(":")
  raise PinholeError.new(file: caller_infos[0], line: caller_infos[1], **hash)
end

class Blacksmith
  include HTTParty
  base_uri ENV['REACTOR_TEST_URL']

  def initialize
    required = %w(REACTOR_TEST_URL REACTOR_TEST_API_KEY REACTOR_TEST_API_TOKEN REACTOR_ORG_ID)
    if required.any? { |k| ENV[k].to_s.empty? }
      msg = "Your environment has not been set up.\n" +
        "You have at least one missing value:\n"
      required.each { |k| msg += "\n  #{k} is #{ENV[k].inspect}" }
      raise Oops(error: msg)
    end

    @base_uri = ENV['REACTOR_TEST_URL']
    @default_headers = {
      'Accept' => 'application/vnd.api+json;revision=1',
      'Content-Type' => 'application/vnd.api+json',
      'X-Api-Key' => ENV['REACTOR_TEST_API_KEY'],
      'Authorization' => "Bearer #{ENV['REACTOR_TEST_API_TOKEN']}"
    }
  end

  def to_s
    @base_uri
  end

  def headers(new_headers)
    all_headers = @default_headers.merge(new_headers)
  end

  def pretty_json(json_text)
    JSON.pretty_generate(JSON.parse(json_text))
  end

  # verb is a symbol in the set { :get, :post, :patch, :put, :delete }
  # options keys are in the set { :headers, :body, :query, ... }
  # (there are many other option keys supported; see
  # https://github.com/jnunemaker/httparty/blob/master/lib/httparty/request.rb)
  def perform_request(verb, uri, options)
    puts "#{verb.to_s.upcase} #{uri}" if $Verbose >= 2
    opts = options.dup
    opts[:headers] = @default_headers.merge(options.fetch(:headers, {}))
    puts "headers: #{opts[:headers]}" if $Verbose >= 4 && opts[:headers]
    if opts[:body]
      opts[:body] = opts[:body].to_json unless String === opts[:body]
      puts "body: #{pretty_json(opts[:body])}" if $Verbose >= 3
    end
    response = self.class.send(verb, uri, **opts)
    puts "#{response.code} #{response.message}" if $Verbose >= 3 ||
      $Verbose >= 2 && (response.code < 200 || 300 <= response.code)
    puts "headers: #{response.headers}" if $Verbose >= 4 && response.headers
    puts "body: #{pretty_json(response.body)}" if $Verbose >= 3 && response.body
    puts "#{response}" if $Verbose >= 4
    response_to_entities verb.to_s.upcase, uri, response
  end

  def create(uri, **options)
    perform_request(:create, uri, options)
  end

  def get(uri, **options);
    perform_request(:get, uri, options)
  end

  def post(uri, **options)
    perform_request(:post, uri, options)
  end

  def patch(uri, **options)
    perform_request(:patch, uri, options)
  end

  def delete(uri, **options)
    perform_request(:delete, uri, options)
  end

  # Construct a Blacksmith Entity from (the Ruby-objects representation of)
  # a JSONAPI response.
  def jsonapi_to_entity(response, data)
    data['type'].classify.constantize.make(self, data, response: response)
  rescue => error
    raise Oops(
      error: 'Cannot construct Entity from data',
      data: data,
      wrapped: error,
    )
  end

  def response_to_entities(verb, request_uri, response)
    if 200 <= response.code && response.code < 300
      return nil if response.headers['content-length'] == "0"
      return nil if response.headers['content-type'] == nil;
      if response.headers['content-type'] =~ %r{^application/vnd.api\+json}
        ##### require "json-api-vanilla"
        ##### doc = JSON::Api::Vanilla.json(response.body)
        ##### pp(doc)
        body = response.parsed_response || JSON.parse(response.body)
        raise_html_error(response, body['errors']) if body.key? 'errors'
        data = body['data']
        return jsonapi_to_entity(response, data) if Hash === data
        return data.map {|item| jsonapi_to_entity(response, item) } if Array === data
        raise Oops(
          error: %q(invalid payload['data'] type),
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

  # find(klass, *args, **keywords): return an Entity object filled with data
  # from the server.  The args and keywords are passed directly to the klass's
  # `search_uri` method.
  # For example,
  #   blacksmith.find(Property, 'PR00000000000000000000000000001234')
  # is equivalent to
  #   blacksmith.get(Property.search_uri('PR00000000000000000000000000001234')
  def find(klass, *args, **keywords)
    get(klass.search_uri(*args, **keywords))
  end
end

# base class for Blacksmith objects
class Entity
  attr_reader :server, :id, :name

  # If x is an Entity, load it into its class's cache.
  # Else, assume x is an entity ID and return its cache entry, if any.
  #
  # This code manages a separate cache for each subclass of Entity.
  # Each class's cache contains all its instances, indexed by id.
  #   In Org, this manages a cache of Orgs.
  #   In Property, this manages a cache of Properties.
  #   etc.
  def self.cache(x)
    @cache ||= {}
    raise "Use #{self.class.name}#find rather than " +
      "#{self.class.name}.new" if Entity === x && @cache.key?(x.id)
    Entity === x ? (@cache[x.id] = x) : @cache[x]
  end

  # find(context, id): return an instance of self whose id is `id`.
  # This isn't called 'get' so as to avoid confusion with HTML GET requests.
  #
  # `context` is a hash with these keys:
  #   :any     a lambda which must return an appropriate instance of self
  #   :new     a lambda which must return a new faked instance of self
  #   :all     a lambda which must return a list of all appropriate instances
  #
  # The `id` may be nil, an Entity instance, or a string.
  # If id=='NEW', a new faked instance is created and returned.
  # If id=='ONE', returns some existing instance, or a new fake if none exists.
  # If id=='ANY', returns some existing instance, or nil if none exists.
  # If id=='ALL', returns a list of all existing instances; [] if none exist.
  # If id is some other string, returns the instance with that ID.
  # If id==nil,   returns nil.
  # If id is an entity, returns that entity.
  def self.find(server, id:, context: nil)
    server.is_a?(Blacksmith) or die "bad server reference: #{server.inspect}"
    case id
    when nil
      nil
    when Entity
      entity = id
    when 'ALL'
      puts "Find all #{self.name.pluralize}" if $Verbose >= 1
      entity = context[:all].call
    when 'ANY'
      puts "Find any #{self.name}" if $Verbose >= 1
      entity = context[:any].call
      raise "Cannot find ANY #{self.name}" unless entity
      entity
    when 'NEW'
      puts "Make new #{self.name}" if $Verbose >= 1
      entity = context[:new].call
    when 'ONE'
      puts "Find one #{self.name}" if $Verbose >= 1
      entity = context[:any].call || context[:new].call
    when String
      puts "Find the #{self.name} #{id}" if $Verbose >= 1
      entity = self.cache(id) || self.new(server, id)
    else
      raise "Cannot build #{self.name} from #{id.inspect}"
    end
  ensure
    if $Verbose >= 1
      entity_list = *entity
      trace(entity)
    end
  end

  # Find or create an instance of data['type'] whose id is data['id'].
  # `data` is the parsed form of an entity's JSONAPI representation.
  def self.make(server, data, response: nil)
    server.is_a?(Blacksmith) or die "bad server reference: #{server.inspect}"
    id = data['id']
    entity = self.cache(id) || self.new(server, id)
    entity.instance_variable_set("@loaded", true)
    entity.instance_variable_set("@data", data)
    name = data&.dig('attributes', 'name')
    entity.instance_variable_set("@name", name) if name
    request_id = response&.headers&.dig('x-request-id')
    entity.instance_variable_set("@request_id", request_id) if request_id
    entity.copy_from_json(data)
  end

  def self.trace(entity)
    if $Verbose >= 1
      entity_list = *entity
      entity_list.each do |entity|
        req_id = entity.request_id
        req = req_id ? " #{req_id=*req_id; req_id[0]}" : ""
        name = entity.name && entity.name != '' ? %Q[ "#{entity.name}"] : ''
        puts "  #{entity.id}#{req}#{name}"
      end
    end
  end

  def initialize(server, id)
    server.is_a?(Blacksmith) or die "bad server reference: #{server.inspect}"
    @server, @id, @loaded = server, id, false
    self.class.cache(self)
  end

  def load
    @loaded ? self : @server.find(self.class, id: @id)
  end

  def request_id
    @request_id
  end

  def name
    return @name if @name
    self.load unless @loaded
    @name = @data.dig('attributes', 'name') || '' if @data
  end

  def data
    return @data if @data
    self.load unless @loaded
    @data
  end

  # Initialize this entity's instance variables from JSONAPI data.
  # `data` is the parsed form of this entity's JSONAPI representation.
  def copy_from_json(data)
    raise Oops(
      source: "#{self.class}##{__callee__}",
      error: "Cannot create #{self.class} from data type #{data['type'].inspect}"
    ) unless data['type'].classify == self.class.name
    @id = data['id'] if !@id
    raise Oops(
      source: "#{self.class}##{__callee__}",
      error: "ID conflict"
    ) unless @id == data['id']
    data['attributes'].each { |k, v| self.instance_variable_set("@#{k}", v) }
    @loaded = true
    return self
  rescue => error
    raise Oops(
      error: "Cannot initialize #{self.class} instance from data",
      data: data,
      wrapped: error,
    )
  end

  def to_s
    "#{@id} #{@name.inspect}"
  end
end

class Org < Entity
  def self.find(server, id:, context: nil)
    @cache ||= {}
    @cache[id] ||= Org.new(server, id)
    return @cache[id]
  end

  # WARNING: @companies_list and @companies_hash do not get updated when new
  # Companies are created.
  # TODO: fix this by using Org.find in Companies.initialize)
  def companies
    unless @companies_list
      companies = @server.get("/companies?filter[org_id]=EQ%20#{@id}")
      companies = *companies
      # The `x = *y` idiom ensures that @companies_list is a list. It converts:
      #   nil => [], c => [c], [] => [], [c] => [c], [c,...] => [c,...]
      @companies_list = *companies
    end
    @companies_hash ||= @companies_list.each_with_object({}) do |company, hash|
      hash[company.id] = company
    end
    @companies_list
  end

  # WARNING: @extension_packages_list and @extension_packages_hash do not get
  # updated when new Extension Packages are created.
  def extension_packages
    unless @extension_packages_list
      extension_packages = @server.get("/extension_packages")
      extension_packages = *extension_packages
      # The `x = *y` idiom ensures that @extension_packages_list is a list. It converts:
      #   nil => [], c => [c], [] => [], [c] => [c], [c,...] => [c,...]
      @extension_packages_list = *extension_packages
    end
    @extension_packages_hash ||= @extension_packages_list.each_with_object({}) do |ep, hash|
      hash[ep.id] = ep
    end
    @extension_packages_list
  end

  # Returns the requested company associated with this Org.
  # (Currently, there is only ever one company on an org.)
  # As in Entity.find, id may be nil/company/'ANY'/'NEW'/'ONE'/id.
  def company(id)
    Company.find(@server, id: id, context: {
      any: lambda { companies.first },
      new: lambda { Company.fake(org: self) },
      all: lambda { companies },
    })
  end

  # Returns the requested Extension Package.
  # As in Entity.find, id may be nil/extension_package/'ANY'/'NEW'/'ONE'/id.
  def extension_package(id)
    ExtensionPackage.find(@server, id: id, context: {
      any: lambda { ExtensionPackage.core(@server) },
      new: lambda { ExtensionPackage.fake(org: self) },
      all: lambda { extension_packages },
    })
  end
end

class Heartbeat < Entity
  # Return the URI to search for a company by org_id (defaults to
  # $REACTOR_ORG_ID)
  def self.search_uri()
    "/heartbeat"
  end

  def self.get(server)
    server.is_a?(Blacksmith) or die "bad server reference: #{server.inspect}"
    server.get("/heartbeat")
  end
end

class User < Entity
  # Return the URI to search for a company by org_id (defaults to
  # $REACTOR_ORG_ID)
  def self.search_uri()
    "/profile"
  end

  def self.profile(server)
    server.is_a?(Blacksmith) or die "bad server reference: #{server.inspect}"
    user = server.get("/profile")
    Entity.trace(user)
  end
end

class Company < Entity

  # Return the URI to search for a company by org_id (defaults to
  # $REACTOR_ORG_ID)
  def self.search_uri(id: nil)
    raise "invalid Company ID '#{id}'" unless id =~ /^CO[0-9a-fA-F]{32}$/
    "/companies/#{id}"
  end

  def self.all(server)
    server.is_a?(Blacksmith) or die "bad server reference: #{server.inspect}"
    dummyCorp = Company.new(server, 'DUMMY')
    Entity.trace(dummyCorp.all)  # why is this necessary? shouldn't build do it?
  end

  def all
    @server.get('/companies')
  end


  def org=(org_id)
    @org_id = org_id
  end

  def properties
    # NOTE: This version doesn't trace, even when $Verbose. To get a trace,
    # use company.property('ALL') instead.
    @server.get("/companies/#{@id}/properties")
  end

  # Returns the requested property associated with this Company.
  # As in Entity.find, id may be nil/property/'ANY'/'NEW'/'ONE'/id.
  def property(id)
    Property.find(@server, id: id, context: {
      all: lambda { properties },
      any: lambda { properties.first },
      new: lambda { Property.fake(company: self) },
    })
  end

  def self.fake(org:)
    company_name = FFaker::Company.name
    org.server.post("/companies", body: {
      data: {
        type: 'companies',
        attributes: {
          name: company_name,
          org_id: org.id,
        },
      }
    }).tap { |company| company.org = org }
  end
end

class Property < Entity
  # Return the URI to search for a property by property_id
  def self.search_uri(id: nil)
    raise "invalid Property ID '#{id}'" unless id =~ /^PR[0-9a-fA-F]{32}$/
    "/properties/#{id}"
  end

  def company=(company)
    @company = company
  end

  def delete
    puts "Kill the Property #{@id}" if $Verbose >= 1
    @server.delete("/properties/#{@id}")
  end

  def adapters
    @server.get("/properties/#{@id}/adapters")
  end

  def builds
    raise "Cannot get Builds from a Property; use Library as source instead"
  end

  def callbacks
    @server.get("/properties/#{@id}/callbacks")
  end

  def data_elements
    @server.get("/properties/#{@id}/data_elements")
  end

  def extensions
    @server.get(extension_uri)
  end

  def libraries
    @server.get("/properties/#{@id}/libraries")
  end

  def rules
    @server.get("/properties/#{@id}/rules")
  end

  # Returns the requested Adapter associated with this Property.
  # As in Entity.find, id may be nil/adapter/'ANY'/'NEW'/'ONE'/id.
  def adapter(id)
    Adapter.find(@server, id: id, context: {
      any: lambda { adapters.first },
      new: lambda { Adapter.fake(property: self) },
      all: lambda { adapters },
    })
  end

  # Returns the requested callback associated with this Property.
  # As in Entity.find, id may be nil/callback/'ANY'/'NEW'/'ONE'/id.
  def callback(id)
    Callback.find(@server, id: id, context: {
      any: lambda { callbacks.first },
      new: lambda { Callback.fake(org: self) },
      all: lambda { callbacks },
    })
  end

  # Returns the requested DataElement associated with this Property.
  # As in Entity.find, id may be nil/data_element/'ANY'/'NEW'/'ONE'/id.
  def data_element(id)
    DataElement.find(@server, id: id, context: {
      all: lambda { data_elements },
      any: lambda { data_elements.first },
      new: lambda { DataElement.fake(property: self) },
    })
  end

  # Returns the requested Environment associated with this Property.
  # As in Entity.find, id may be nil/environment/'ANY'/'NEW'/'ONE'/id.
  def environment(id, adapter:)
    Environment.find(@server, id: id, context: {
      any: lambda { environment.first },
      new: lambda { Environment.fake(property: self, adapter: adapter) },
    })
  end

  # Returns the requested Extensions associated with this Property.
  # As in Entity.find, id may be nil/extension/'ANY'/'NEW'/'ONE'/id.
  def extension(id, extension_package:nil)
    Extension.find(@server, id: id, context: {
      all: lambda { extensions },
      any: lambda { extensions.first },
      new: lambda {
        raise "#{self.class.name}#{__callee__}: extension_package req'd for 'NEW'" unless extension_package
        make_extension(property: self, extension_package: extension_package)
      },
    })
  end

  # Returns the requested Library associated with this Property.
  # As in Entity.find, id may be nil/library/'ANY'/'NEW'/'ONE'/id.
  def library(id, environment:nil)
    Library.find(@server, id: id, context: {
      all: lambda { libraries },
      any: lambda { libraries.first },
      new: lambda {
        raise "#{self.class.name}#{__callee__}: environment req'd for 'NEW'" unless environment
        Library.fake(property: self, environment: environment)
      },
    })
  end

  # Returns the requested Rule associated with this Property.
  # As in Entity.find, id may be nil/rule/'ANY'/'NEW'/'ONE'/id.
  def rule(id)
    Rule.find(@server, id: id, context: {
      all: lambda { rules },
      any: lambda { rules.first },
      new: lambda { Rule.fake(property: self) }, #TODO
    })
  end

  def environment_uri(environment=nil)
    "/properties/#{@id}/environments" + (environment ? "/#{environment.id}" : '')
  end

  def library_uri(library=nil)
    "/properties/#{@id}/libraries" + (library ? "/#{library.id}" : '')
  end

  def extension_uri(extension=nil)
    if extension
      "/extensions/#{extension.id}"
    else
      "/properties/#{@id}/extensions"
    end
  end

  def make_extension(extension_package:)
    @server.post(extension_uri, body: {
      data: {
        type: 'extensions',
        attributes: {
        },
        relationships: {
          extension_package: {
            data: {
              id: extension_package.id,
              type: "extension_packages",
            }
          }
        }
      }
    })
  end

  def self.fake(company:)
    property_name = FFaker::Company.name
    domain = FFaker::Internet.domain_name
    company.server.post("/companies/#{company.id}/properties", body: {
      data: {
        type: 'properties',
        attributes: {
          name: property_name,
          domains: ["#{FFaker::Internet::domain_word}.#{domain}"],
          platform: 'web',
        },
      }
    }).tap { |property| property.company = company }
  end
end

class Adapter < Entity
  # Return the URI to search for an adapter by adapter_id
  def self.search_uri(id: nil)
    raise "invalid Adapter ID '#{id}'" unless id =~ /^AD[0-9a-fA-F]{32}$/
    "/adapters/#{id}"
  end

  def property=(property)
    @property = property
  end

  def self.fake(property:)
    adapter_name = "#{FFaker::Product.brand} #{FFaker::Product.model} Adapter"
    #host = "#{FFaker::Internet::domain_word}.#{FFaker::Internet.domain_name}"
    host = "adobeio.com"
    property.server.post("/properties/#{property.id}/adapters", body: {
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
    }).tap { |adapter| adapter.property = property }
  end
end

class Environment < Entity
  def property=(property)
    @property = property
  end

  def adapter
    @server.get("/environments/#{@id}/adapter")
  end

  def self.fake(property:, adapter:)
    environment_name = "#{FFaker::Animal.common_name} Environment"
    payload = {
      data: {
        type: 'environments',
        attributes: {
          name: environment_name,
          stage: 'development',
          path: '/foo/bar',
        },
        relationships: {
          adapter: { data: { type: 'adapters', id: adapter.id } }
        }
      }
    }
    property.server.post(property.environment_uri, body: payload).tap do
      |environment| environment.property = property
    end
  end
end

class Library < Entity
  # Return the URI to search for a library by library_id
  def self.search_uri(id: nil)
    raise "invalid Library ID '#{id}'" unless id =~ /^LB[0-9a-fA-F]{32}$/
    "/libraries/#{id}"
  end

  def self.fake(property:, environment:)
    library_name = "#{FFaker::Product.model} #{FFaker::Animal.common_name} Library"
    payload = {
      data: {
        type: 'libraries',
        attributes: { name: library_name },
        relationships: {
          environment: { data: { type: 'environments', id: environment.id } }
        }
      }
    }
    property.server.post(property.library_uri, body: payload).tap do
      |library| library.property = property
    end
  end

  def property=(property)
    @property = property
  end

  def build_uri(build=nil)
    "/libraries/#{@id}/builds" + (build ? "/#{build.id}" : '')
  end

  def start_build
    puts "Make new build of #{@id} #{@name}" if $Verbose >= 1
    b = @server.post(build_uri).tap { |b|
      b.library = self
      Entity.trace(b)
    }
  end

  def builds
    # NOTE: This version doesn't trace, even when $Verbose. To get a trace,
    # use library.build('ALL') instead.
    @server.get("/libraries/#{@id}/builds")
  end

  # Returns the requested build associated with this Library.
  # As in Entity.find, id may be nil/id/build/'ANY'/'NEW'/'ONE'/'ALL'.
  def build(id)
    Build.find(@server, id: id, context: {
      all: lambda { builds },
      any: lambda { builds.first },
      new: lambda { start_build },
    })
  end

  def resources
    # NOTE: This doesn't trace.
    @server.get("/libraries/#{@id}/resources")
  end

  # Returns the requested resource associated with this Company.
  # As in Entity.find, id may be nil/id/property/'ANY'/'NEW'/'ONE'/'ALL'.
  def property(id)
    Property.find(@server, id: id, context: {
      all: lambda { resources },
      any: lambda { resources.first },
      new: lambda { Property.fake(company: self) },
    })
  end

  def link_resources(*resource_ids)
    data = resource_ids.map { |id| { id: id, type: id_to_type(id) } }
    @server.post("/libraries/#{@id}/relationships/resources", body: { data: data })
  end
end

class ExtensionPackage < Entity
  # Return the URI to search for an Extension Package by id.
  def self.search_uri(id: nil)
    raise "invalid ExtensionPackage ID '#{id}'" unless id =~ /^EP[0-9a-fA-F]{32}$/
    "/extension_packages/#{id}"
  end

  def self.kessel_test(server)
    ep = server.get('/extension_packages?filter[name]=EQ%20kessel-test')
    ep = *ep
    ep[0]
  end

  def self.core(server)
    ep = server.get('/extension_packages?filter[name]=EQ%20core')
    ep = *ep
    ep[0]
  end
end

class Build < Entity
  # Return the URI to search for a Build by id
  def self.search_uri(id:)
    raise "invalid Build ID '#{id}'" unless id =~ /^BL[0-9a-fA-F]{32}$/
    "/builds/#{id}"
  end

  def environment
    @server.get("/builds/#{@id}/environment")
  end

  def library=(library)
    @library = library
  end
end

class Callback < Entity
  # Return the URI to search for a Build by id
  def self.search_uri(id:)
    raise "invalid Callback ID '#{id}'" unless id =~ /^CB[0-9a-fA-F]{32}$/
    "/callbacks/#{id}"
  end
end

class Resource < Entity
  def revise
    type = self.class.name.pluralize.underscore
    rev = server.patch("/#{type}/#{id}", body: {
      data: {
        attributes: { },
        meta: { action: "revise" },
        id: id,
        type: type,
      }
    });
    Entity.trace(rev) if $Verbose >= 1
    rev
  end

  def revisions
    type = self.class.name.pluralize.underscore
    revs = @server.get("/#{type}/#{id}/revisions");
    Entity.trace(revs) if $Verbose >= 1
    revs
  end
end

class Extension < Resource
  # Return the URI to search for an extension by id
  def self.search_uri(id:)
    raise "invalid Extension ID '#{id}'" unless id =~ /^EX[0-9a-fA-F]{32}$/
    "/extensions/#{id}"
  end
end

class Rule < Resource
  # Return the URI to search for a Rule by id
  def self.search_uri(id:)
    raise "invalid Rule ID '#{id}'" unless id =~ /^RL[0-9a-fA-F]{32}$/
    "/rules/#{id}"
  end

  def rule_components
    rcs = @server.get("/rules/#{id}/rule_components");
    Entity.trace(rcs) if $Verbose >= 1
    rcs
  end

  def rule_component(rc_id)
    RuleComponent.find(@server, id: rc_id, context: {
      any: lambda { rule_components.first },
      new: lambda { RuleComponent.fake(rule: self) }, #TODO
      all: lambda { rule_components },
    })
  end
end

class RuleComponent < Resource
  # Return the URI to search for a RuleComponent by id
  def self.search_uri(id:)
    raise "invalid Rule ID '#{id}'" unless id =~ /^RC[0-9a-fA-F]{32}$/
    "/rule_components/#{id}"
  end

  def rule_id
    return @rule_id if @rule_id
    self.load unless @loaded
    @rule_id = @data.dig('relationships', 'rule', 'data', 'id')
  end
end

class DataElement < Resource
  # Return the URI to search for a DataElement by id
  def self.search_uri(id:)
    raise "invalid DataElement ID '#{id}'" unless id =~ /^DE[0-9a-fA-F]{32}$/
    "/data_elements/#{id}"
  end
end
