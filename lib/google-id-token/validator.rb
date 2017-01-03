require 'multi_json'
require 'jwt'
require 'openssl'
require 'net/http'

module GoogleIDToken
  class Validator

    GOOGLE_CERTS_URI = 'https://www.googleapis.com/oauth2/v1/certs'

    # @!attribute [r] problem
    #   Reason for failure, if #check returns nil
    attr_reader :problem

    def initialize(keyopts = {})
      if keyopts[:x509_cert]
        @certs_mode = :literal
        @certs = { :_ => keyopts[:x509_cert] }
      # elsif keyopts[:jwk_uri]  # TODO
      #   @certs_mode = :jwk
      #   @certs = {}
      else
        @certs_mode = :old_skool
        @certs = {}
      end

    end

    ##
    # If it validates, returns a hash with the JWT fields from the ID Token.
    #  You have to provide an "aud" value, which must match the
    #  token's field with that name, and will similarly check cid if provided.
    #
    # If something fails, returns nil; #problem returns error text
    #
    # @param [String] token
    #   The string form of the token
    # @param [String] aud
    #   The required audience value
    # @param [String] cid
    #   The optional client-id ("azp" field) value
    #
    # @return [Hash] The decoded ID token, or null
    def check(token, aud, cid = nil)
      case check_cached_certs(token, aud, cid)
      when :valid
        @token
      when :problem
        nil
      else
        # no certs worked, might've expired, refresh
        if refresh_certs
          @problem = 'Unable to retrieve Google public keys'
          nil
        else
          case check_cached_certs(token, aud, cid)
          when :valid
            @token
          when :problem
            nil
          else
            @problem = 'Token not verified as issued by Google'
            nil
          end
        end
      end
    end

    private

    # tries to validate the token against each cached cert.
    # Returns :valid (sets @token) or :problem (sets @problem) or
    #  nil, which means none of the certs validated.
    def check_cached_certs(token, aud, cid)
      @problem = @token = @tokens = nil

      # find first public key that validates this token
      @certs.detect do |key, cert|
        begin
          public_key = cert.public_key
          @token = JWT.decode(token, public_key, !!public_key)

          # Support for JWT 1.x version
          if @token.is_a?(Array)
            @token = @token[0]
          end

          # in Feb 2013, the 'cid' claim became the 'azp' claim per changes
          #  in the OIDC draft. At some future point we can go all-azp, but
          #  this should keep everything running for a while
          if @token['azp']
            @token['cid'] = @token['azp']
          elsif @token['cid']
            @token['azp'] = @token['cid']
          end
        rescue JWT::DecodeError
          nil # go on, try the next cert
        end
      end

      if @token
        if !(@token.has_key?('aud') && (@token['aud'] == aud))
          @problem = 'Token audience mismatch'
        elsif cid && !(@token.has_key?('cid') && (@token['cid'] == cid))
          @problem = 'Token client-id mismatch'
        end
        @problem ? :problem : :valid
      else
        nil
      end
    end

    # returns true if there was a problem
    def refresh_certs
      case @certs_mode
      when :literal
        return # no-op
      when :old_skool
        old_skool_refresh_certs
      # when :jwk          # TODO
      #  jwk_refresh_certs
      end
    end

    def old_skool_refresh_certs
      uri = URI(GOOGLE_CERTS_URI)
      get = Net::HTTP::Get.new uri.request_uri
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      res = http.request(get)

      if res.kind_of?(Net::HTTPSuccess)
        new_certs = Hash[MultiJson.load(res.body).map do |key, cert|
                           [key, OpenSSL::X509::Certificate.new(cert)]
                         end]
        @certs.merge! new_certs
        false
      else
        true
      end
    end
  end
end
