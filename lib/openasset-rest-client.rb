
require_relative 'Version/version.rb'

require_relative 'Authenticator.rb'
require_relative 'RestOptions.rb'
require_relative 'Helpers.rb'
require_relative 'Validator.rb'

require 'net/http'

#Includes all the nouns in one shot
Dir[File.join(File.dirname(__FILE__),'Nouns','*.rb')].each { |file| require_relative file }

module OpenAsset
	class RestClient
		
		RESTRICTED_LIST_FIELD_TYPES   = %w[ suggestion fixedSuggestion option ]
		NORMAL_FIELD_TYPES 		      = %w[ singleLine multiLine ]
		ALLOWED_BOOLEAN_FIELD_OPTIONS = %w[ enable disable yes no set unset check uncheck tick untick on off true false 1 0]

		# @!parse attr_reader :session, :uri
		attr_reader :session, :uri
		
		# @!parse attr_accessor :verbose
		attr_accessor :verbose

		# Create new instance of the OpenAsset rest client
		#
		# @param client_url [string] Cloud client url
		# @return [RestClient object]
		#
		# @example 
		#         rest_client = OpenAsset::RestClient.new('se1.openasset.com')
		def initialize(client_url)
			oa_uri_with_protocol    = Regexp::new('(^https:\/\/|http:\/\/)\w+.+\w+.openasset.(com)$', true)
			oa_uri_without_protocol = Regexp::new('^\w+.+\w+.openasset.(com)$', true)

			unless oa_uri_with_protocol =~ client_url #check for valid url and that protocol is specified
				if oa_uri_without_protocol =~ client_url #verify correct url format
					client_url = "https://" + client_url #add the https protocol if one isn't provided
				else
					warn "Error: Invalid url! Expected http(s)://<subdomain>.openasset.com" + 
						 "\nInstead got => #{uri}"
					exit
				end
			end
			@authenticator = Authenticator::get_instance(client_url)
			@uri = @authenticator.uri
			@session = @authenticator.get_session
			@verbose = false
		end

		private
		# @!visibility private
		def generate_objects_from_json_response_body(json_response,resource_type)

				parsed_response_body = JSON.parse(json_response.body)

				if parsed_response_body.is_a?(Array) && (parsed_response_body.empty? == false)

					inferred_class = Object.const_get(resource_type)
					
					objects_array = parsed_response_body.map { |item| inferred_class.new(item) }

				else
					# return raw JSON response if empty body comes back
					json_response
				end
	
		end 

		# @!visibility private 
		def get_count(object=nil,rest_option_obj=nil) #can be used to get count of other resources in the future
			resource = (object) ? object.class.to_s : object
			query    = (rest_option_obj) ? rest_option_obj.get_options : ''
			unless Validator::NOUNS.include?(resource)
				abort("Argument Error: Expected Nouns Object for first argument in #{__callee__}. Instead got #{resource}") 
			end

			unless rest_option_obj.is_a?(RestOptions) || rest_option_obj == nil
				abort("Argument Error: Expected RestOptions Object or no argument for second argument in #{__callee__}." + 
						"\n\tInstead got #{rest_option_obj.inspect}") 
			end

			uri = URI.parse(@uri + '/' + resource + query)								   

			response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
				request = Net::HTTP::Head.new(uri.request_uri)
				if @session
					request.add_field('X-SessionKey',@session)
				else
					@session = @authenticator.get_session
					request.add_field('X-SessionKey',@session) #For when the token issue is sorted out
					#request['authorization'] = "Basic YWRtaW5pc3RyYXRvcjphZG1pbg=="
				end
				http.request(request)
			end

			unless @session == response['X-SessionKey']
				@session = response['X-SessionKey']
			end

			Validator::process_http_response(response,@verbose,resource,'HEAD')
			response['X-Full-Results-Count'].to_i
		end

		# @!visibility private
		def get(uri,options_obj)
			resource = uri.to_s.split('/').last
			options = options_obj || RestOptions.new

			#Ensures File resource query returns all nested file sizes unless otherwise specified
			case resource 
			when 'Files'
				options.add_option('sizes','all')
				options.add_option('keywords','all')
				options.add_option('fields','all')
			when 'Albums'
				options.add_option('files','all')
				options.add_option('groups','all')
				options.add_option('users','all')
			when 'Projects'
				options.add_option('projectKeywords','all')
				options.add_option('fields','all')
				options.add_option('albums','all')
			when 'Fields'
				options.add_option('fieldLookupStrings','all')
			when 'Searches'
				options.add_option('groups','all')
				options.add_option('users','all')
			else
				
			end
			
			response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
				
				#Account for 2048 character limit with GET requests
				options_str_len = options.get_options.length
				if options_str_len > 1024
					request = Net::HTTP::Post.new(uri.request_uri + options.get_options)
					request.add_field('X-Http-Method-Override','GET')
				else
					request = Net::HTTP::Get.new(uri.request_uri + options.get_options)
				end

				if @session
					request.add_field('X-SessionKey',@session)
				else
					@session = @authenticator.get_session
					request.add_field('X-SessionKey',@session) 
				end
				http.request(request)
			end

			unless @session == response['X-SessionKey']
				@session = response['X-SessionKey']
			end
			Validator::process_http_response(response,@verbose,resource,'GET')
				
			#Dynamically infer the the class needed to create objects by using the request_uri REST endpoint
			#returns the Class constant so we can dynamically set it below

			inferred_class = Object.const_get(resource)
		    
			objects_array = JSON.parse(response.body).map { |item| inferred_class.new(item) }
			
		end

		# @!visibility private
		def post(uri,data,generate_objects)
			resource = ''
			if uri.to_s.split('/').last.to_i == 0 #its a non numeric string meaning its a resource endpoint
				resource = uri.to_s.split('/').last
			else
				resource = uri.to_s.split('/')[-2] #the request is using a REST shortcut so we need to grab 
			end									   #second to last string of the url as the endpoint

			json_body = Validator::validate_and_process_request_data(data)
			unless json_body
				puts "Error: Undefined json_body Error in POST request."
				return false
			end
			response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
				request = Net::HTTP::Post.new(uri.request_uri)
				if @session
					request.add_field('X-SessionKey',@session)
				else
					@session = @authenticator.get_session
					request.add_field('X-SessionKey',@session) #For when the token issue is sorted out
					#request['authorization'] = "Basic YWRtaW5pc3RyYXRvcjphZG1pbg=="
				end
				request.body = json_body.to_json
				http.request(request)
			end

			unless @session == response['X-SessionKey']
				@session = response['X-SessionKey']
			end

			Validator::process_http_response(response,@verbose,resource,'POST')

			if generate_objects

				generate_objects_from_json_response_body(response,resource)

			else
				# JSON object
				response

			end

		end

		# @!visibility private
		def put(uri,data,generate_objects)
			resource = uri.to_s.split('/').last
			json_body = Validator::validate_and_process_request_data(data)
			unless json_body
				return
			end
			response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
				request = Net::HTTP::Put.new(uri.request_uri)
				if @session
					request.add_field('X-SessionKey',@session)
				else
					@session = @authenticator.get_session
					request.add_field('X-SessionKey',@session) #For when the token issue is sorted out
					#request['authorization'] = "Basic YWRtaW5pc3RyYXRvcjphZG1pbg=="
				end
				request.body = json_body.to_json
				http.request(request)
			end

			unless @session == response['X-SessionKey']
				@session = response['X-SessionKey']
			end

			Validator::process_http_response(response,@verbose,resource,'PUT')

			if generate_objects

				generate_objects_from_json_response_body(response,resource)

			else
				# JSON object
				response

			end
			
		end

		# @!visibility private
		def delete(uri,data)
			resource = uri.to_s.split('/').last
			json_object = Validator::validate_and_process_delete_body(data)
			unless json_object
				return
			end
			response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
				request = Net::HTTP::Delete.new(uri.request_uri) #e.g. when called in keywords => /keywords/id
				if @session
					request.add_field('X-SessionKey',@session)
				else
					@session = @authenticator.get_session
					request.add_field('X-SessionKey',@session) #For when the token issue is sorted out
					#request['authorization'] = "Basic YWRtaW5pc3RyYXRvcjphZG1pbg=="
				end
				request.body = json_object.to_json
				http.request(request)
			end

			unless @session == response['X-SessionKey']
				@session = response['X-SessionKey']
			end

			Validator::process_http_response(response,@verbose,resource,'DELETE')

			response
		end
		
		public
		#########################
		#                       #
		#   Session Management  #
		#                       #
		#########################

		# Destroys current session
		#
		# @return [nil] Does not return anything.
		# 
		# @example rest_client.kill_session()
		def kill_session
			@authenticator.kill_session
		end

		# Generates a new session
		#
		# @return [nil] Does not return anything.
		# 
		# @example rest_client.get_session()
		def get_session
			@authenticator.get_session
		end

		# Destroys current session and Generates new one
		#
		# @return [nil] Does not return anything.
		# 
		# @example rest_client.renew_session()
		def renew_session
			@authenticator.kill_session
			@authenticator.get_session
		end
		
		####################################################
		#                                                  #
		#  Retrieve, Create, Modify, and Delete Resources  #
		#                                                  #
		####################################################


		#################
		#               #
		# ACCESS LEVELS #
		#               #
		#################

		# Retrieves Access Levels.
		#
		# @param query_obj [RestOptions Object] Takes a RestOptions object containing query string (Optional)
		# @return [Array] Returns an array of AccessLevels objects.
		#
		# @example 
		#          rest_client.get_access_levels
		#          rest_client.get_access_levels(rest_options_object)
		def get_access_levels(query_obj=nil)
			uri = URI.parse(@uri + "/AccessLevels")
			results = get(uri,query_obj)
		end

		##########
		#        #
		# ALBUMS #
		#        #
		##########

		# Retrieves Albums.
		#
		# @param query_obj [RestOptions Object] Takes a RestOptions object containing query string (Optional)
		# @return [Array] Returns an array of Albums objects.
		#
		# @example 
		#          rest_client.get_albums()
		#          rest_client.get_albums(rest_options_object)
		def get_albums(query_obj=nil)	
			uri = URI.parse(@uri + "/Albums")
			result = get(uri,query_obj)
		end

		# Create Albums.
		#
		# @param data [Single Albums Object, Array of Albums Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns an Albums objects array if generate_objects flag is set
		#
		# @example
		#          rest_client.create_albums(albums_obj)
		#          rest_client.create_albums(albums_obj_array)
		#     	   rest_client.create_albums(albums_obj,true)
		#          rest_client.create_albums(albums_obj_array,true)
		def create_albums(data=nil,generate_objects=false)
			uri = URI.parse(@uri + '/Albums')
			result = post(uri,data,generate_objects)
		end

		# Modify Albums.
		#
		# @param data [Single Albums Object, Array of Albums Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns an Albums objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_albums(albums_obj)
		#          rest_client.update_albums(albums_obj,true)
		#          rest_client.update_albums(albums_obj_array)
		#          rest_client.update_albums(albums_obj_array,true)
		def update_albums(data=nil,generate_objects=false)
			uri = URI.parse(@uri + '/Albums')
			result = put(uri,data,generate_objects) 
		end
		
		# Delete Albums.
		#
		# @param data [Single Albums Object, Array of Albums Objects, Integer, String, Integer Array, Numeric String Array (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example 
		#          rest_client.delete_albums(albums_obj)
		#          rest_client.delete_albums(albums_objects_array)
		#          rest_client.delete_albums([1,2,3])
		#          rest_client.delete_albums(['1','2','3'])
		#          rest_client.delete_albums(1)
		#          rest_client.delete_albums('1')
		def delete_albums(data=nil)
			uri = URI.parse(@uri + '/Albums')
			result = delete(uri,data)
		end

		####################
		#                  #
		# ALTERNATE STORES #
		#                  #
		####################

		# Retrieves Alternate Stores.
		#
		# @param query_obj [RestOptions Object] Takes a RestOptions object containing query string (Optional)
		# @return [Array] Returns an array of AlternateStores objects.
		#
		# @example 
		#          rest_client.get_alternate_stores()
		#          rest_client.get_alternate_stores(rest_options_object)
		def get_alternate_stores(query_obj=nil)
			uri = URI.parse(@uri + "/AlternateStores")
			results = get(uri,query_obj)
		end

		#################
		#               #
		# ASPECT RATIOS #
		#               #
		#################

		# Retrieves Aspect Ratios.
		#
		# @param query_obj [RestOptions Object] Takes a RestOptions object containing query string (Optional)
		# @return [Array] Returns an array of AspectRatios objects.
		#
		# @example 
		#          rest_client.get_aspect_ratios()
		#          rest_client.get_aspect_ratios(rest_options_object)
		def get_aspect_ratios(query_obj=nil)
			uri = URI.parse(@uri + "/AspectRatios")
			results = get(uri,query_obj)
		end

		##############
		#            #
		# CATEGORIES #
		#            #
		##############

		# Retrieves system Categories (not keyword categories).
		#
		# @param query_obj [RestOptions Object] Takes a RestOptions object containing query string (Optional)
		# @return [Array] Returns an array of Categories objects.
		#
		# @example 
		#          rest_client.get_categories()
		#          rest_client.get_categories(rest_options_object)
		def get_categories(query_obj=nil)
			uri = URI.parse(@uri + "/Categories")
			results = get(uri,query_obj)
		end

		# Modify system Categories.
		#
		# @param data [Single CopyrightPolicies Object, Array of CopyrightPolicies Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns a Categories objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_categories(categories_obj)
		#          rest_client.update_categories(categories_obj,true)
		#          rest_client.update_categories(categories_obj_array)
		#          rest_client.update_categories(categories_obj_array,true)	
		def update_categories(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Categories")
			results = put(uri,data,generate_objects)
		end

		#####################
		#                   #
		# COPYRIGHT HOLDERS #
		#                   #
		#####################

		# Retrieves CopyrightHolders.
		#
		# @param query_obj [RestOptions Object] Takes a RestOptions object containing query string (Optional)
		# @return [Array] Returns an array of CopyrightHolders objects. 
		#
		# @example 
		#          rest_client.get_copyright_holders()
		#          rest_client.get_copyright_holders(rest_options_object)
		def get_copyright_holders(query_obj=nil)
			uri = URI.parse(@uri + "/CopyrightHolders")
			results = get(uri,query_obj)
		end

		# Create CopyrightHoloders.
		#
		# @param data [Single CopyrightPolicies Object, Array of CopyrightPolicies Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after object creation
		# @return [JSON object] HTTP response JSON object. Returns a CopyrightHolders objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.create_copyright_holders(copyright_holders_obj)
		#          rest_client.create_copyright_holders(copyright_holders_obj_array)
		#          rest_client.create_copyright_holders(copyright_holders_obj,true)
		#          rest_client.create_copyright_holders(copyright_holders_obj_array,true)	
		def create_copyright_holders(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/CopyrightHolders")
			results = post(uri,data,generate_objects)
		end

		# Modify CopyrightHolders.
		#
		# @param data [Single CopyrightHolders Object, Array of CopyrightHoloders Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns a CopyrightHolders objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_copyright_holders(copyright_holders_obj)
		#          rest_client.update_copyright_holders(copyright_holders_obj,true)
		#          rest_client.update_copyright_holders(copyright_holders_obj_array)
		#          rest_client.update_copyright_holders(copyright_holders_obj_array,true)	
		def update_copyright_holders(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/CopyrightHolders")
			results = put(uri,data,generate_objects)
		end

		######################
		#                    #
		# COPYRIGHT POLICIES #
		#                    #
		######################

		# Retrieves CopyrightPolicies.
		#
		# @param query_obj [RestOptions Object] Takes a RestOptions object containing query string (Optional)
		# @return [Array] Returns an array of CopyrightPolicies objects.
		#
		# @example 
		#          rest_client.get_copyright_policies()
		#          rest_client.get_copyright_policies(rest_options_object)
		def get_copyright_policies(query_obj=nil)
			uri = URI.parse(@uri + "/CopyrightPolicies")
			results = get(uri,query_obj)
		end

		# Create CopyrightPolicies.
		#
		# @param data [Single CopyrightPolicies Object, Array of CopyrightPolicies Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after object creation
		# @return [JSON object] HTTP response JSON object. Returns a CopyrightPolicies objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.create_copyright_policies(copyright_policies_obj)
		#          rest_client.create_copyright_policies(copyright_policies_obj_array)
		#          rest_client.create_copyright_policies(copyright_policies_obj,true)
		#          rest_client.create_copyright_policies(copyright_policies_obj_array,true)		
		def create_copyright_policies(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/CopyrightPolicies")
			results = post(uri,data,generate_objects)
		end

		# Modify CopyrightPolicies.
		#
		# @param data [Single CopyrightPolicies Object, Array of CopyrightPolicies Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns a CopyrightPolicies objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_copyright_policies(copyright_policies_obj)
		#          rest_client.update_copyright_policies(copyright_policies_obj,true)
		#          rest_client.update_copyright_policies(copyright_policies_obj_array)
		#          rest_client.update_copyright_policies(copyright_policies_obj_array,true)	
		def update_copyright_policies(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/CopyrightPolicies")
			results = put(uri,data,generate_objects)
		end

		# Disables CopyrightPolicies.
		#
		# @param data [Single CopyrightPolicies Object, CopyrightPolicies Objects Array, Integer, Integer Array, Numeric String, Numeric String Array] (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example 
		#          rest_client.delete_copyright_policies(copyright_policies_obj)
		#          rest_client.delete_copyright_policies(copyright_policies_obj_array)
		#          rest_client.delete_copyright_policies([1,2,3])
		#          rest_client.delete_copyright_policies(['1','2','3'])
		#          rest_client.delete_copyright_policies(1)
		#          rest_client.delete_copyright_policies('1')		
		def delete_copyright_policies(data=nil)
			uri = URI.parse(@uri + "/CopyrightPolicies")
			results = delete(uri,data)
		end

		##########
		#        #
		# FIELDS #
		#        #
		##########

		# Retrieves Fields.
		#
		# @param query_obj [RestOptions Object] Takes a RestOptions object containing query string (Optional)
		# @return [Array] Returns an array of Fields objects.
		#
		# @example 
		#          rest_client.get_fields()
		#          rest_client.get_fields(rest_options_object)
		def get_fields(query_obj=nil)
			uri = URI.parse(@uri + "/Fields")
			results = get(uri,query_obj)
		end

		# Create fields.
		#
		# @param data [Single Fields Object, Array of Fields Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after object creation
		# @return [JSON object] HTTP response JSON object. Returns a Fields objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.create_fields(fields_obj)
		#          rest_client.create_fields(fields_obj_array)
		#          rest_client.create_fields(fields_obj,true)
		#          rest_client.create_fields(fields_obj_array,true)	
		def create_fields(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Fields")
			results = post(uri,data,generate_objects)
		end

		# Modify fields.
		#
		# @param data [Single Fields Object, Array of Fields Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns a Fields objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_fields(fields_obj)
		#          rest_client.update_fields(fields_obj,true)
		#          rest_client.update_fields(fields_obj_array)
		#          rest_client.update_fields(fields_obj_array,true)	
		def update_fields(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Fields")
			results = put(uri,data,generate_objects)
		end

		# Disable fields.
		#
		# @param data [Single Fields Object, Array of Fields Objects, Integer, Integer Array, Numeric String, Numeric String Array]
		# @return [JSON object] HTTP response JSON object.
		#
		# @example 
		#          rest_client.delete_fields(fields_obj)
		#          rest_client.delete_fields(fields_obj_array)
		#          rest_client.delete_fields([1,2,3])
		#          rest_client.delete_fields(['1','2','3'])
		#          rest_client.delete_fields(1)
		#          rest_client.delete_fields('1')	
		def delete_fields(data=nil)
			uri = URI.parse(@uri + "/Fields")
			results = delete(uri,data)
		end

		########################
		#                      #
		# FIELD LOOKUP STRINGS #
		#                      #
		########################

		# Retrieves options for Fixed Suggestion, Suggestion, and Option field types.
		#
		# @param field [Fields Object, Hash, String, Integer] Argument must specify the field id (Required)
		# @param query_obj[RestOptions Object] Specify query parameters string (Optional)
		# @return [Array] Array of FieldLookupStrings.
		#
		# @example 
		#          rest_client.get_field_lookup_strings()
		#          rest_client.get_field_lookup_strings(rest_options_object)
		def get_field_lookup_strings(field=nil,query_obj=nil)
			id = Validator::validate_field_lookup_string_arg(field)
			
			uri = URI.parse(@uri + '/Fields' + "/#{id}" +'/FieldLookupStrings')
			results = get(uri,query_obj)
		end

		# creates options for Fixed Suggestion, Suggestion, and Option field types.
		#
		# @param field [Fields Object, Hash, String, Integer] Argument must specify the field id (Required)
		# @param data [Single FieldLookupString Object, Array of FieldLookupString Objects]
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after object creation
		# @return [JSON object] HTTP response JSON object. Returns Array of FieldLookupStrings objects if generate_objects flag is set
		#
		# @example 
		#          rest_client.create_field_lookup_strings(field_obj,field_lookup_strings_obj)
		#          rest_client.create_field_lookup_strings(field_obj,field_lookup_strings_obj,true)
		#          rest_client.create_field_lookup_strings(field_obj,field_lookup_strings_obj_array)
		#          rest_client.create_field_lookup_strings(field_obj,field_lookup_strings_obj_array,true)	
		def create_field_lookup_strings(field=nil,data=nil,generate_objects=false)
			id = Validator::validate_field_lookup_string_arg(field)
			
			uri = URI.parse(@uri + '/Fields' + "/#{id}" +'/FieldLookupStrings')
			results = post(uri,data,generate_objects)
		end

		# Modifies options for Fixed Suggestion, Suggestion, and Option field types.
		#
		# @param field [Fields Object, Hash, String, Integer] Argument must specify the field id (Required)
		# @param data [Single FieldLookupString Object, Array of FieldLookupString Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns Array of FieldLookupStrings objects if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_field_lookup_strings(field_obj,field_lookup_strings_obj)
		#          rest_client.update_field_lookup_strings(field_obj,field_lookup_strings_obj,true)
		#          rest_client.update_field_lookup_strings(field_obj,field_lookup_strings_obj_array)
		#          rest_client.update_field_lookup_strings(field_obj,field_lookup_strings_obj_array,true)	
		def update_field_lookup_strings(field=nil,data=nil,generate_objects=false)
			id = Validator::validate_field_lookup_string_arg(field)
			
			uri = URI.parse(@uri + '/Fields' + "/#{id}" +'/FieldLookupStrings')
			results = put(uri,data,generate_objects)
		end

		# Delete an item and/or option for Fixed Suggestion, Suggestion, and Option field types.
		#
		# @param field [Fields Object, String, Integer] Argument must specify the field id
		# @param data [Single FieldLookupString Object, Array of FieldLookupString Objects, Integer, Integer Array, Numeric String, Numeric String Array]
		# @return [JSON object] HTTP response JSON object.
		#
		# @example 
		#          rest_client.delete_fields_lookup_strings(field_obj, field_lookup_strings_obj)
		#          rest_client.delete_fields_lookup_strings(field_obj, field_lookup_strings_obj_array)
		#          rest_client.delete_fields_lookup_strings(field_obj, [1,2,3])
		#          rest_client.delete_fields_lookup_strings(field_obj, ['1','2','3'])
		#          rest_client.delete_fields_lookup_strings(field_obj, 1)
		#          rest_client.delete_fields_lookup_strings(field_obj, '1')
		def delete_field_lookup_strings(field=nil,data=nil)

			id = Validator::validate_field_lookup_string_arg(field)
			
			uri = URI.parse(@uri + '/Fields' + "/#{id}" +'/FieldLookupStrings')
			results = delete(uri,data) #data parameter validated in private delete method
		end

		#########
		#       #
		# Files #
		#       #
		#########

		# Retrieves Files objects with ALL nested resources - including their nested image sizes - from OpenAsset.
		#
		# @param query_obj [RestOptions Object] Takes a RestOptions object containing query string (Optional)
		# @return [Array] Returns an array of Files objects.
		#
		# @example 
		#          rest_client.get_files()
		#          rest_client.get_files(rest_options_object)
		def get_files(query_obj=nil)
			uri = URI.parse(@uri + "/Files")
			results = get(uri,query_obj)
		end

		# Uploads a file to OpenAsset.
		#
		# @param file [String] the path to the file being uploaded
		# @param category [Categories Object,String,Integer] containing Target Category ID in OpenAsset (Required)
		# @param project [Projects Object, String, Integer] Project ID in OpenAsset (Specified only when Category is project based)
		# @return [JSON Object] HTTP response JSON object. Returns Files objects array if generate_objects flag is set
		#
		# FOR PROJECT UPLOADS
		# @example rest_client.upload_file('/path/to/file', category_obj, project_obj)
		#  		   rest_client.upload_file('/path/to/file','2','10')
		# 		   rest_client.upload_file('/path/to/file', 2, 10)
		#          rest_client.upload_file('/path/to/file', category_obj, project_obj, true)
		#          rest_client.upload_file('/path/to/file','2','10', true)
		#          rest_client.upload_file('/path/to/file', 2, 10, true)
		#
		#
		# FOR REFERENCE UPLOADS
		# @example rest_client.upload_file('/path/to/file', category_obj)
		#          rest_client.upload_file('/path/to/file','2')
		#          rest_client.upload_file('/path/to/file', 2,)
		#          rest_client.upload_file('/path/to/file', category_obj, nil, true)
		#          rest_client.upload_file('/path/to/file','2', nil, true)
		#          rest_client.upload_file('/path/to/file', 2, nil, true)
		def upload_file(file=nil, category=nil, project=nil, generate_objects=false) 
		
			unless File.exists?(file.to_s)
				puts "Error: The file provided does not exist -\"#{file}\"...Bailing out."
				return false
			end

			unless category.is_a?(Categories) || category.to_i > 0
				puts "Argument Error for upload_files method: Invalid category id passed to second argument.\n" +
				     "Acceptable arguments: Category object, a non-zero numeric String or Integer, " +
				     "or no argument.\nInstead got #{category.class}...Bailing out."
				return false
			end

			unless project.is_a?(Projects) || project.to_i > 0 || project.nil?
				puts "Argument Error for upload_files method: Invalid project id passed to third argument.\n" +
				     "Acceptable arguments: Projects object, a non-zero numeric String or Integer, " +
				     "or no argument.\nInstead got a(n) #{project.class} with value => #{project.inspect}...Bailing out."
				return false
			end

			category_id = nil
			project_id  = nil

			if category.is_a?(Categories)
				category_id = category.id
			else
				category_id = category
			end

			if project.is_a?(Projects)
				project_id = project.id
			elsif project.nil?
				project_id = ''
			else
				project_id = project
			end

			uri = URI.parse(@uri + "/Files")
			boundary = (0...50).map { (65 + rand(26)).chr }.join #genererate a random str thats 50 char long
			body = Array.new

			response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
				request = Net::HTTP::Post.new(uri.request_uri)
				
				if @session
					request.add_field('X-SessionKey',@session)
				else
					@session = @authenticator.get_session
					request.add_field('X-SessionKey',@session)
				end

				request["cache-control"] = 'no-cache'
				request["content-type"] = 'multipart/form-data; boundary=----WebKitFormBoundary' + boundary

				body << "------WebKitFormBoundary#{boundary}\r\nContent-Disposition: form-data; name=\"_jsonBody\"" 
				body << "\r\n\r\n[{\"original_filename\":\"#{File.basename(file)}\",\"category_id\":#{category_id},\"project_id\":\"#{project_id}\"}]\r\n"
				body << "------WebKitFormBoundary#{boundary}\r\nContent-Disposition: form-data; name=\"file\";"
				body << "filename=\"#{File.basename(file)}\"\r\nContent-Type: #{MIME::Types.type_for(file)}\r\n\r\n"
				body << IO.binread(file)
				body << "\r\n------WebKitFormBoundary#{boundary}--"

				request.body = body.join
				http.request(request)
			end

			Validator::process_http_response(response,@verbose,'Files','POST')

			if generate_objects
				
				generate_objects_from_json_response_body(response)

			else
				# JSON Object
				response

			end	
		end

		# Replace a file in OpenAsset.
		#
		# @param original_file_object [Single Files Object] (Required)
		# @param replacement_file_path [String] (Required)
		# @param retain_original_filename_in_oa [Boolean] (Optional)
		# @param generate_objects [Boolean] Return an array of Files or JSON objects in response body (Default => false)
		# @return [JSON object or Files Object Array ]. Returns Files objects array if generate_objects flag is set
		def replace_file(original_file_object=nil, replacement_file_path='', retain_original_filename_in_oa=false, generate_objects=false) 
			file_object = (original_file_object.is_a?(Array)) ? original_file_object.first : original_file_object
			uri = URI.parse(@uri + "/Files")
			id = file_object.id.to_s
			original_filename = nil

			# raise an Error if something other than an file object is passed in. Check the class
			unless file_object.is_a?(Files) 
				puts "ARGUMENT ERROR: First argument => Invalid object type! Expected File object" +
				     " and got #{file_obj.class} object instead. Aborting update." 
				return false
			end
			
			if File.directory?(replacement_file_path)
				puts "ARGUMENT ERROR: Second argument => Expected a file! " +
					 "#{replacement_file_path} is a directory! Aborting update."
			end


			#check if the replacement file exists
			unless File.exists?(replacement_file_path) && File.file?(replacement_file_path)
				puts "ERROR: The file #{replacement_file_path} does not exist. Aborting update."
				return false
			end

			#verify that both files have the same file extentions otherwise you will
			#get a 400 Bad Request Error
			if File.extname(file_object.original_filename) != File.extname(replacement_file_path)
				puts "ERROR: File extensions must match! Aborting update\n\t" + 
					 "Original file extension => #{File.extname(file_object.original_filename)}\n\t" +
					 "Replacement file extension => #{File.extname(replacement_file_path)}"
				return false
			end

			#verify that the original file id is provided
			unless id != "0"
				puts "ERROR: Invalid target file id! Aborting update."
				return false
			end

			#change in format
			if retain_original_filename_in_oa == true
				unless file_object.original_filename == nil || file_object.original_filename == ''
	
					original_filename = File.basename(file_object.original_filename)
				else
					warn "ERROR: No original filename detected in Files object. Aborting update."
					return false
				end
			else
				original_filename = File.basename(replacement_file_path)
			end 

			body = Array.new

			response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
				request = Net::HTTP::Put.new(uri.request_uri)
				request["content-type"] = 'multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW'
				if @session
					request.add_field('X-SessionKey',@session)
				else
					@session = @authenticator.get_session
					request.add_field('X-SessionKey',@session)
				end
				request["cache-control"] = 'no-cache'
				body << "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\nContent-Disposition: form-data; name=\"_jsonBody\""  
				body << "\r\n\r\n[{\"id\":\"#{id}\",\"original_filename\":\"#{original_filename}\"}]\r\n"
				body << "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\nContent-Disposition: form-data; name=\"file\";" 
				body << "filename=\"#{original_filename}\"\r\nContent-Type: #{MIME::Types.type_for(original_filename)}\r\n\r\n"
				body << IO.binread(replacement_file_path)
				body << "\r\n------WebKitFormBoundary7MA4YWxkTrZu0gW--"
				request.body = body.join
				http.request(request)
			end
			Validator::process_http_response(response,@verbose,'Files', 'PUT')

			if generate_objects
				
				generate_objects_from_json_response_body(response)

			else
				# JSON Object
				response
			end
				
		end

		# Download Files.
		#
		# @param files [Single Files Object, Array of Files Objects] (Required)
		# @param image_size [Integer, String] (Accepts image size id or postfix string: 
		# 					Defaults to '1' => original image size id)
		# @param download_location [String] (Default: Creates folder called Rest_Downloads in the current directory.)
		# @return [nil].
		def download_files(files=nil,image_size='1',download_location='./Rest_Downloads')
			#Put single files objects in an array for easy downloading with 
			#the Array class' DownloadHelper module
			files = [files]  unless files.is_a?(Array)

			files.download(image_size,download_location)
		end

		# Update Files.
		#
		# @param data [Single Files Object, Array of Files Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns Files objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_files(files_obj)
		#          rest_client.update_files(files_obj,true)
		#          rest_client.update_files(files_obj_array)
		#          rest_client.update_files(files_obj_array,true)
		def update_files(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Files")
			results = put(uri,data,generate_objects)
		end

		# Delete Files.
		#
		# @param data [Single Files Object, Array of Files Objects, Integer, Integer Array, Numeric String, Numeric String Array] (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example 
		#          rest_client.delete_files(files_obj)
		#          rest_client.delete_files(files_obj_array)
		#          rest_client.delete_files([1,2,3])
		#          rest_client.delete_files(['1','2','3'])
		#          rest_client.delete_files(1)
		#          rest_client.delete_files('1')
		def delete_files(data=nil)
			uri = URI.parse(@uri + "/Files")
			results = delete(uri,data)
		end
        
        ##########
		#        #
		# GROUPS #
		#        #
		##########

		# Retrieves Groups.
		#
		# @param query_obj[RestOptions Object] Specify query parameters string (Optional)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example rest_client.get_groups()
		# @example rest_client.get_groups(rest_options_object)
		def get_groups(query_obj=nil)
			uri = URI.parse(@uri + "/Groups")
			results = get(uri,query_obj)
		end

		############
		#          #
		# KEYWORDS #
		#          #
		############

		# Retrieves file keywords.
		#
		# @param query_obj[RestOptions Object] Specify query parameters string (Optional)
		# @return [Array] Array of Keywords objects.
		#
		# @example rest_client.get_keywords()
		# @example rest_client.get_keywords(rest_options_object)
		def get_keywords(query_obj=nil)
			uri = URI.parse(@uri + "/Keywords")
			results = get(uri,query_obj)
		end

		# Create new file Keywords in OpenAsset.
		#
		# @param data [Single Keywords Object, Array of Keywords Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after object creation
		# @return [JSON object] HTTP response JSON object. Returns Keywords objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.create_keywords(keywords_obj)
		#          rest_client.create_keywords(keywords_obj_array)	
		#          rest_client.create_keywords(keywords_obj,true)
		#          rest_client.create_keywords(keywords_obj_array,true)	
		def create_keywords(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Keywords")
			results = post(uri,data,generate_objects)
		end

		# Modify file Keywords.
		#
		# @param data [Single Keywords Object, Array of Keywords Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns Keywords objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_keywords(keywords_obj)
		#          rest_client.update_keywords(keywords_obj,true)
		#          rest_client.update_keywords(keywords_obj_array)
		#          rest_client.update_keywords(keywords_obj_array,true)
		def update_keywords(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Keywords")
			results = put(uri,data,generate_objects)
		end

		# Delete Keywords.
		#
		# @param data [Single Keywords Object, Array of Keywords Objects, Integer, Integer Array, Numeric String, Numeric String Array] (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example 
		#          rest_client.delete_keywords(keywords_obj)
		#          rest_client.delete_keywords(keywords_obj_array)
		#          rest_client.delete_keywords([1,2,3])
		#          rest_client.delete_keywords(['1','2','3'])
		#          rest_client.delete_keywords(1)
		#          rest_client.delete_keywords('1')
		def delete_keywords(data=nil)
			uri = URI.parse(@uri + "/Keywords")
			results = delete(uri,data)
		end

		######################
		#                    #
		# KEYWORD CATEGORIES #
		#                    #
		######################

		# Retrieve file keyword categories.
		#
		# @param query_obj[RestOptions Object] Specify query parameters string (Optional)
		# @return [Array] Array of KeywordCategories objects.
		#
		# @example rest_client.get_keyword_categories()
		# @example rest_client.get_keyword_categories(rest_options_object)
		def get_keyword_categories(query_obj=nil)
			uri = URI.parse(@uri + "/KeywordCategories")
			results = get(uri,query_obj)
		end

		# Create file keyword categories.
		#
		# @param data [Single KeywordCategories Object, Array of KeywordCategories Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after object creation
		# @return [JSON object] HTTP response JSON object. Returns KeywordCategories objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.create_keyword_categories(keyword_categories_obj)
		#          rest_client.create_keyword_categories(keyword_categories_obj_array)	
		#          rest_client.create_keyword_categories(keyword_categories_obj,true)
		#          rest_client.create_keyword_categories(keyword_categories_obj_array,true)
		def create_keyword_categories(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/KeywordCategories")
			results = post(uri,data,generate_objects)
		end

		# Modify file keyword categories.
		#
		# @param data [Single KeywordCategories Object, Array of KeywordCategories Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object.. Returns KeywordCategories objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_keyword_categories(keyword_categories_obj)
		#          rest_client.update_keyword_categories(keyword_categories_obj,true)
		#          rest_client.update_keyword_categories(keyword_categories_obj_array)
		#          rest_client.update_keyword_categories(keyword_categories_obj_array,true)
		def update_keyword_categories(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/KeywordCategories")
			results = put(uri,data,generate_objects)
		end

		# Delete Keyword Categories.
		#
		# @param data [Single KeywordCategories Object, KeywordCategories Objects Array, Integer, Integer Array, Numeric String, Numeric String Array] (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example 
		#          rest_client.delete_keyword_categories(keyword_categories_obj)
		#          rest_client.delete_keyword_categories(keyword_categories_obj_array)
		#          rest_client.delete_keyword_categories([1,2,3])
		#          rest_client.delete_keyword_categories(['1','2','3'])
		#          rest_client.delete_keyword_categories(1)
		#          rest_client.delete_keyword_categories('1')
		def delete_keyword_categories(data=nil)
			uri = URI.parse(@uri + "/KeywordCategories")
			results = delete(uri,data)
		end

		#################
		#               #
		# PHOTOGRAPHERS #
		#               #
		#################

		# Retrieve photographers.
		#
		# @param query_obj[RestOptions Object] Specify query parameters string (Optional)
		# @return [Array] Array of Photographers objects.
		#
		# @example rest_client.get_photographers()
		# @example rest_client.get_photographers(rest_options_object)
		def get_photographers(query_obj=nil)
			uri = URI.parse(@uri + "/Photographers")
			results = get(uri,query_obj)
		end

		# Create Photographers.
		#
		# @param data [Single Photographers Object, Array of Photographers Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after object creation
		# @return [JSON object] HTTP response JSON object. Returns Photographers objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.create_photographers(photographers_obj)
		#          rest_client.create_photographers(photographers_obj,true)
		#          rest_client.create_photographers(photographers_obj_array)
		#          rest_client.create_photographers(photographers_obj_array,true)
		def create_photographers(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Photographers")
			results = post(uri,data,generate_objects)
		end

		# Modify Photographers.
		#
		# @param data [Single Photographers Object, Array of Photographers Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns Photographers objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_photographers(photographers_obj)
		#          rest_client.update_photographers(photographers_obj,true)
		#          rest_client.update_photographers(photographers_obj_array)
		#          rest_client.update_photographers(photographers_obj_array,true)
		def update_photographers(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Photographers")
			results = put(uri,data,generate_objects)
		end

		############
		#          #
		# PROJECTS #
		#          #
		############

		# Retrieve projects
		#
		# @param query_obj[RestOptions Object] Specify query parameters string (Optional)
		# @return [Array] Array of Projects objects.
		#
		# @example rest_client.get_projects()
		# @example rest_client.get_projects(rest_options_object)
		def get_projects(query_obj=nil)
			uri = URI.parse(@uri + "/Projects")
			results = get(uri,query_obj)
		end

		# Create Projects.
		#
		# @param data [Single Projects Object, Array of Projects Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after object creation
		# @return [JSON object] HTTP response JSON object. Returns Projects objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.create_projects(projects_obj)
		#          rest_client.create_projects(projects_obj,true)
		#          rest_client.create_projects(projects_obj_array)
		#          rest_client.create_projects(projects_obj_array,true)	
		def create_projects(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Projects")
			results = post(uri,data,generate_objects)
		end

		# Modify Projects.
		#
		# @param data [Single Projects Object, Array of Projects Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns Projects objects array if generate_objects flag is set
		#
		#
		# @example 
		#          rest_client.update_projects(projects_obj)
		#          rest_client.update_projects(projects_obj,true)
		#          rest_client.update_projects(projects_obj_array)
		#          rest_client.update_projects(projects_obj_array,true)
		def update_projects(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Projects")
			results = put(uri,data,generate_objects)
		end

		# Delete Projects.
		#
		# @param data [Single KProjects Object, Array of Projects Objects, Integer, Integer Array, Numeric String, Numeric String Array] (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example 
		#          rest_client.delete_projects(projects_obj)
		#          rest_client.delete_projects(projects_obj_array)
		#          rest_client.delete_projects([1,2,3])
		#          rest_client.delete_projects(['1','2','3'])
		#          rest_client.delete_projects(1)
		#          rest_client.delete_projects('1')
		def delete_projects(data=nil)
			uri = URI.parse(@uri + "/Projects")
			results = delete(uri,data)
		end

		####################
		#                  #
		# PROJECT KEYWORDS #
		#                  #
		####################

		# Retrieve project keywords.
		#
		# @param query_obj[RestOptions Object] Specify query parameters string (Optional)
		# @return [Array] Array of ProjectKeywords objects.
		#
		# @example rest_client.get_project_keywords()
		# @example rest_client.get_project_keywords(rest_options_object)
		def get_project_keywords(query_obj=nil)
			uri = URI.parse(@uri + "/ProjectKeywords")
			results = get(uri,query_obj)
		end

		# Create Project Keywords.
		#
		# @param data [Single ProjectKeywords Object, Array of ProjectKeywords Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after object creation
		# @return [JSON object] HTTP response JSON object. Returns ProjectKeywords objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.create_project_keywords(project_keywords_obj)
		#          rest_client.create_project_keywords(project_keywords_obj,true)	
		#          rest_client.create_project_keywords(project_keywords_obj_array)
		#          rest_client.create_project_keywords(project_keywords_obj_array,true)
		def create_project_keywords(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/ProjectKeywords")
			results = post(uri,data,generate_objects)
		end

		# Modify Project Keywords.
		#
		# @param data [Single ProjectKeywords Object, Array of ProjectKeywords Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns ProjectKeywords objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_project_keywords(project_keywords_obj)
		#          rest_client.update_project_keywords(project_keywords_obj,true)
		#          rest_client.update_project_keywords(project_keywords_obj_array)
		#          rest_client.update_project_keywords(project_keywords_obj_array,true)
		def update_project_keywords(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/ProjectKeywords")
			results = put(uri,data,generate_objects)
		end

		# Delete Project Keywords.
		#
		# @param data [Single ProjectKeywords Object, Array of ProjectKeywords Objects, Integer, Integer Array, Numeric String, Numeric String Array] (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example 
		#          rest_client.delete_project_keywords(project_keywords_obj)
		#          rest_client.delete_project_keywords(project_keywords_obj_array)
		#          rest_client.delete_project_keywords([1,2,3])
		#          rest_client.delete_project_keywords(['1','2','3'])
		#          rest_client.delete_project_keywords(1)
		#          rest_client.delete_project_keywords('1')
		def delete_project_keywords(data=nil)
			uri = URI.parse(@uri + "/ProjectKeywords")
			results = delete(uri,data)
		end

		##############################
		#                            #
		# PROJECT KEYWORD CATEGORIES #
		#                            #
		##############################

		# Retrieve project keyword categories.
		#
		# @param query_obj[RestOptions Object] Specify query parameters string (Optional)
		# @return [Array] Array of ProjectKeywordCategories objects.
		#
		# @example rest_client.get_project_keyword_categories()
		# @example rest_client.get_project_keyword_categories(rest_options_object)
		def get_project_keyword_categories(query_obj=nil)
			uri = URI.parse(@uri + "/ProjectKeywordCategories")
			results = get(uri,query_obj)
		end

		# Create project keyword categories.
		#
		# @param data [Single ProjectKeywordCategories Object, Array of ProjectKeywordCategories Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after object creation
		# @return [JSON object] HTTP response JSON object. Returns ProjectKeywordCategories objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.create_project_keyword_categories(project_keyword_categories_obj)
		#          rest_client.create_project_keyword_categories(project_keyword_categories_obj,true)	
		#          rest_client.create_project_keyword_categories(project_keyword_categories_obj_array)	
		#          rest_client.create_project_keyword_categories(project_keyword_categories_obj_array,true)	
		def create_project_keyword_categories(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/ProjectKeywordCategories")
			results = post(uri,data,generate_objects)
		end

		# Modify project keyword categories.
		#
		# @param data [Single ProjectKeywordCategories Object, Array of ProjectKeywordCategories Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns ProjectKeywordCategories objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_project_keyword_categories(project_keyword_categories_obj)
		#          rest_client.update_project_keyword_categories(project_keyword_categories_obj,true)
		#          rest_client.update_project_keyword_categories(project_keyword_categories_obj_array)
		#          rest_client.update_project_keyword_categories(project_keyword_categories_obj_array,true)
		def update_project_keyword_categories(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/ProjectKeywordCategories")
			results = put(uri,data,generate_objects)
		end

		# Delete Project Keyword Categories.
		#
		# @param data [Single ProjectKeywordCategories Object, Array of ProjectKeywordCategories Objects, Integer, Integer Array, Numeric String, Numeric String Array] (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example 
		#          rest_client.delete_project_keyword_categories(project_keyword_categories_obj)
		#          rest_client.delete_project_keyword_categories(project_keyword_categories_obj_array)
		#          rest_client.delete_project_keyword_categories([1,2,3])
		#          rest_client.delete_project_keyword_categories(['1','2','3'])
		#          rest_client.delete_project_keyword_categories(1)
		#          rest_client.delete_project_keyword_categories('1')
		def delete_project_keyword_categories(data=nil)
			uri = URI.parse(@uri + "/ProjectKeywordCategories")
			results = delete(uri,data)
		end

		############
		#          #
		# SEARCHES #
		#          #
		############

		# Retrieve searches.
		#
		# @param query_obj[RestOptions Object] Specify query parameters string (Optional)
		# @return [Array] Array of Searches objects.
		#
		# @example rest_client.get_searches()
		# @example rest_client.get_searches(rest_options_object)
		def get_searches(query_obj=nil)
			uri = URI.parse(@uri + "/Searches")
			results = get(uri,query_obj)
		end

		# Create Searches.
		#
		# @param data [Single Searches Object, Array of Searches Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after object creation
		# @return [JSON object] HTTP response JSON object. Returns Searches objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.create_searches(searches_obj)
		#          rest_client.create_searches(searches_obj,true)	
		#          rest_client.create_searches(searches_obj_array)	
		#          rest_client.create_searches(searches_obj_array,true)	
		def create_searches(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Searches")
			results = post(uri,data,generate_objects)
		end

		# Modify Searches.
		#
		# @param data [Single Searches Object, Array of Searches Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns Searches objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_searches(searches_obj)
		#          rest_client.update_searches(searches_obj,true)
		#          rest_client.update_searches(searches_obj_array)
		#          rest_client.update_searches(searches_obj_array,true)
		def update_searches(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Searches")
			results = put(uri,data,generate_objects)
		end

		#########
		#       #
		# SIZES #
		#       #
		#########

		# Retrieve sizes.
		#
		# @param query_obj[RestOptions Object] Specify query parameters string (Optional)
		# @return [Array] Array of Sizes objects.
		#
		# @example rest_client.get_image_sizes()
		# @example rest_client.get_image_sizes(rest_options_object)
		def get_image_sizes(query_obj=nil)
			uri = URI.parse(@uri + "/Sizes")
			results = get(uri,query_obj)
		end

		# Create image Sizes.
		#
		# @param data [Single Sizes Object, Array of Sizes Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after object creation
		# @return [JSON object] HTTP response JSON object. Returns ImageSizes objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.create_image_sizes(image_sizes_obj)
		#          rest_client.create_image_sizes(image_sizes_obj,true)	
		#          rest_client.create_image_sizes(image_sizes_obj_array)	
		#          rest_client.create_image_sizes(image_sizes_obj_array,true)	
		def create_image_sizes(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Sizes")
			results = post(uri,data,generate_objects)
		end

		# Modify image Sizes.
		#
		# @param data [Single Sizes Object, Array of Sizes Objects] (Required)
		# @param generate_objects [Boolean] (Optional) 
		#        Caution: Hurts performance -> Only use if performing further edits after updating object
		# @return [JSON object] HTTP response JSON object. Returns ImageSizes objects array if generate_objects flag is set
		#
		# @example 
		#          rest_client.update_image_sizes(image_sizes_obj)
		#          rest_client.update_image_sizes(image_sizes_obj,true)	
		#          rest_client.update_image_sizes(image_sizes_obj_array)	
		#          rest_client.update_image_sizes(image_sizes_obj_array,true)	
		def update_image_sizes(data=nil,generate_objects=false)
			uri = URI.parse(@uri + "/Sizes")
			results = put(uri,data,generate_objects)
		end

		# Delete Image Sizes.
		#
		# @param data [Single Sizes Object, Array of Sizes Objects, Integer, Integer Array, Numeric String, Numeric String Array] (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example 
		#          rest_client.delete_image_sizes(image_sizes_obj)
		#          rest_client.delete_image_sizes(image_sizes_obj_array)
		#          rest_client.delete_image_sizes([1,2,3])
		#          rest_client.delete_image_sizes(['1','2','3'])
		#          rest_client.delete_image_sizes(1)
		#          rest_client.delete_image_sizes('1')
		def delete_image_sizes(data=nil)
			uri = URI.parse(@uri + "/Sizes")
			results = delete(uri,data)
		end

		#################
		#               #
		# TEXT REWRITES #
		#               #
		#################

		# Retrieve Text Rewrites.
		#
		# @param query_obj[RestOptions Object] Specify query parameters string (Optional)
		# @return [Array] Array of TextRewrites objects.
		#
		# @example rest_client.get_text_rewrites()
		# @example rest_client.get_text_rewrites(rest_options_object)
		def get_text_rewrites(query_obj=nil)
			uri = URI.parse(@uri + "/TextRewrites")
			results = get(uri,query_obj)
		end

		#########
		#       #
		# USERS #
		#       #
		#########

		# Retrieve Users.
		#
		# @param query_obj[RestOptions Object] Specify query parameters string (Optional)
		# @return [Array] Array of Users objects.
		#
		# @example rest_client.get_users()
		# @example rest_client.get_users(rest_options_object)
		def get_users(query_obj=nil)
			uri = URI.parse(@uri + "/Users")
			results = get(uri,query_obj)
		end

		############################
		#                          #
		# Administrative Functions #
		#                          #
		############################

		# Tag Files with keywords.
		#
		# @param files [Single Files Object, Array of Files Objects] (Required)
		# @param keywords [Single Keywords Object, Array of Keywords Objects] (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example rest_client.file_add_keywords(files_object,keywords_object)
		# @example rest_client.file_add_keywords(files_objects_array,keywords_objects_array)
		# @example rest_client.file_add_keywords(files_object,keywords_objects_array)
		# @example rest_client.file_add_keywords(files_objects_array,project_keywords_object)
		def file_add_keywords(files=nil,keywords=nil)
		
			#1.validate class types
			#Looking for File objects or an array of File objects
			unless files.is_a?(Files) || (files.is_a?(Array) && files.first.is_a?(Files))
				warn "Argument Error: Invalid type for first argument in \"file_add_keywords\" method.\n" +
					 "\tExpected one the following:\n" +
					 "\t1. Single Files object\n" +
					 "\t2. Array of Files objects\n" +
					 "\tInstead got => #{files.inspect}"
				return false			
			end 

			unless keywords.is_a?(Keywords) || (keywords.is_a?(Array) && keywords.first.is_a?(Keywords))
				warn "Argument Error: Invalid type for second argument in \"file_add_keywords\" method.\n" +
					 "\tExpected one the following:\n" +
					 "\t1. Single Keywords object\n" +
					 "\t2. Array of Keywords objects\n" +
					 "\tInstead got => #{keywords.inspect}"
				return false			
			end 
			
			#2.build file json array for request body
			#There are four acceptable combinations for the arguments.
		 
			if files.is_a?(Files)  
				if keywords.is_a?(Keywords) #1. Two Single objects
					uri = URI.parse(@uri + "/Files/#{files.id}/Keywords/#{keywords.id}")
					post(uri,{})
				else						#2. One File object and an array of Keywords objects
					#loop through keywords objects and append the new nested keyword to the file
					keywords.each do |keyword|
						files.keywords << NestedKeywordItems.new(keyword.id)
					end  
					uri = URI.parse(@uri + "/Files")
					put(uri,files)
				end
			else		
				if keywords.is_a?(Array)	#3. Two arrays
					keywords.each do |keyword|
						uri = URI.parse(@uri + "/Keywords/#{keyword.id}/Files")
						data = files.map { |files_obj| {:id => files_obj.id} }
						post(uri,data)
					end
				else						#4. Files array and a single Keywords object
					uri = URI.parse(@uri + "/Keywords/#{keywords.id}/Files")
					data = files.map { |files_obj| {:id => files_obj.id} }
					post(uri,data)
				end
			end
			
		end

		# Tag Projects with keywords.
		#
		# @param projects [Single Projects Object, Array of Projects Objects] (Required)
		# @param proj_keywords [Single ProjectKeywords Object, Array of ProjectKeywords Objects] (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example rest_client.project_add_keywords(projects_object,project_keywords_object)
		# @example rest_client.project_add_keywords(projects_objects_array,project_keywords_objects_array)
		# @example rest_client.project_add_keywords(projects_object,project_keywords_objects_array)
		# @example rest_client.project_add_keywords(projects_objects_array,project_keywords_object)
		def project_add_keywords(projects=nil,proj_keywords=nil)
			
			#1.validate class types
			#Looking for Project objects or an array of Project objects
			unless projects.is_a?(Projects) || (projects.is_a?(Array) && 
					projects.first.is_a?(Projects))
				warn "Argument Error: Invalid type for first argument in \"project_add_keywords\" method.\n" +
					 "\tExpected one the following:\n" +
					 "\t1. Single Projects object\n" +
					 "\t2. Array of Projects objects\n" +
					 "\tInstead got => #{projects.inspect}"
				return false			
			end 

			unless project_keywords.is_a?(ProjectKeywords) || (project_keywords.is_a?(Array) && 
					project_keywords.first.is_a?(ProjectKeywords))
				warn "Argument Error: Invalid type for second argument in \"project_add_keywords\" method.\n" +
					 "\tExpected one the following:\n" +
					 "\t1. Single ProjectKeywords object\n" +
					 "\t2. Array of ProjectKeywords objects\n" +
					 "\tInstead got => #{proj_keywords.inspect}"
				return false			
			end 
			#2.build project json array for request body
			#There are four acceptable combinations for the arguments.
		 	project_keyword = Struct.new(:id)

			if projects.is_a?(Projects)  
				if project_keywords.is_a?(ProjectKeywords) #1. Two Single objects
					uri = URI.parse(@uri + "/Projects/#{projects.id}/ProjectKeywords/#{proj_keywords.id}")
					post(uri,{})
				else						#2. One Project object and an array of project Keyword objects
					#loop through Projects objects and append the new nested keyword to them
					proj_keywords.each do |keyword|
						projects.project_keywords << project_keyword.new(keyword.id)  
					end
					uri = URI.parse(@uri + "/Projects")
					put(uri,projects)
				end
			else 		
				if keywords.is_a?(Array)	#3. Two arrays
					projects.each do |proj|
						proj_keywords.each do |keyword|
							proj.project_keywords << project_keyword.new(keyword.id)
						end
					end
					uri = URI.parse(@uri + "/Projects")
					put(uri,projects)
				else						#4. Projects array and a single Keywords object
					projects.each do |proj|
						proj.project_keywords << project_keyword.new(proj_keywords.id)
					end	
					uri = URI.parse(@uri + "/Projects") #/ProjectKeywords/:id/Projects 
					put(uri,projects)					#shortcut not implemented yet					
				end
			end
		end

		# Add data to ANY File field (built-in or custom).
		#
		# @param file [Files Object] (Required)
		# @param field [Fields Object] (Required)
		# @param value [String, Integer, Float] (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example rest_client.file_add_field_data(files_object,fields_object,'data to be inserted')
		def file_add_field_data(file=nil,field=nil,value=nil)

			#validate class types
			unless file.is_a?(Files) || (file.is_a?(String) && (file.to_i != 0)) || file.is_a?(Integer)
				warn "Argument Error: Invalid type for first argument in \"file_add_field_data\" method.\n" +
					 "\tExpected Single Files object, Numeric string, or Integer for file id\n" +
					 "\tInstead got => #{file.inspect}"
				return			
			end 

			unless field.is_a?(Fields) ||  (field.is_a?(String) && (field.to_i != 0)) || field.is_a?(Integer)
				warn "Argument Error: Invalid type for second argument in \"file_add_field_data\" method.\n" +
					 "\tExpected Single Fields object, Numeric string, or Integer for field id\n" +
					 "\tInstead got => #{field.inspect}"
				return 			
			end

			unless value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Float)
				warn "Argument Error: Invalid type for third argument in \"file_add_field_data\" method.\n" +
					 "\tExpected a String, Integer, or Float\n" +
					 "\tInstead got => #{value.inspect}"
				return			
			end

			current_file  = nil
			current_field = nil
			current_value = value.to_s.strip

			file_class  = file.class.to_s
			field_class = field.class.to_s

			#set up objects
			if file_class == 'Files'
				current_file = file
			elsif file_class == 'String' || file_class == 'Integer' 
				#retrieve Projects object matching id provided
				uri = URI.parse(@uri + "/Files")
				option = RestOptions.new
				option.add_option("id",file.to_s)
				current_file = get(uri,option).first
				unless current_file
					warn "ERROR: Could not find Project with matching id of \"#{file.to_s}\"...Exiting"
					return
				end
			else
				warn "Unknown Error retrieving Files. Exiting."
				return
			end

			if field_class == 'Fields'
				current_field = field
			elsif field_class == 'String' || field_class == 'Integer'
				uri = URI.parse(@uri + "/Fields")
				option = RestOptions.new
				option.add_option("id",field.to_s)
				current_field = get(uri,option).first
				unless current_field
					warn "ERROR: Could not find Field with matching id of \"#{field.to_s}\"\n" +
						 "=> Hint: It either doesn't exist or it's disabled."
					return false
				end
				unless current_field.field_type == "image"
					warn "ERROR: Expected a Project field. The field provided is a \"#{current_field.field_type}\" field."
					return false
				end		
			else
				warn "Unknown Error retrieving Field. Exiting."
				return
			end

			#Prep endpoint to be used for update
			files_endpoint = URI.parse(@uri + "/Files/#{current_file.id}/Fields")

			#Check the field type -> if its option or fixed suggestion we must make the option
			#available first before we can apply it to the Files resource
			if RESTRICTED_LIST_FIELD_TYPES.include?(current_field.field_display_type)
				
				lookup_string_endpoint = URI.parse(@uri + "/Fields/#{current_field.id}/FieldLookupStrings")

				#Grab all the available FieldLookupStrings for the specified Fields resource
				field_lookup_strings = get(lookup_string_endpoint)

				#check if the value in the third argument is currently an available option for the field
				lookup_string_exists = field_lookup_strings.find { |item| item.value == value }

				#add the option to the restricted field first if it's not there, otherwise you get a 400 bad 
				#request error saying that it couldn't find the string value for the restricted field specified 
				#when making a PUT request on the FILES resource you are currently working on
				unless lookup_string_exists
					data = {:value => current_value}
					response = post(lookup_string_endpoint,data)
					return unless response.kind_of? Net::HTTPSuccess
				end

				#Now that we know the option is available, we can update the Files 
				#NOUN we are currently working with using a PUT request
				data = {:id => current_field.id, :values => [current_value]}
				put(files_endpoint,data)

			elsif current_field.field_display_type == "date"
				#make sure we get the right date format
				#Accepts mm-dd-yyyy, mm-dd-yy, mm/dd/yyyy, mm/dd/yy
				date_regex = Regexp::new('((\d{2}-\d{2}-(\d{4}|\d{2}))|(\d{2}\/\d{2}\/(\d{4}|\d{2})))')
				unless (value =~ date_regex) == 0
					warn "ERROR: Invalid date format. Expected => \"mm-dd-yyyy\" or \"mm-dd-yy\""
					return
				end

				value.gsub!('/','-')
				date_arr = value.split('-') #convert date string to array for easy manipulation

				if date_arr.last.length == 2  #convert mm-dd-yy to mm-dd-yyyy format
					four_digit_year = '20' + date_arr.last
					date_arr[-1] = four_digit_year
				end
				#convert date to 14 digit unix time stamp
				value = date_arr[-1] + date_arr[-3] + date_arr[-2] + '000000'

				#Apply the date to our current Files resource
				data = {:id => current_field.id, :values => [value.to_s]}
				put(files_endpoint,data)


			elsif NORMAL_FIELD_TYPES.include?(current_field.field_display_type)
				#some fields are built into Files so they can't be inserted into
				#the Files nested fields resource. We get around this by using the
				#name of the field object to access the corresponding built-in field attribute
				#inside the Files object.
				if current_field.built_in.to_s == "1"  #For built in fields
					files_endpoint =  URI.parse(@uri + '/Files') #change endpoint bc field is builtin
					field_name = current_field.name.downcase.gsub(' ','_') #convert the current field's name
																		   #into the associated files' builtin attribute name
					
					#access built-in field
					unless current_file.instance_variable_defined?('@'+field_name)
						warn "ERROR: The specified attirbute \"#{field_name}\" does not" + 
						     " exist in the File. Exiting."
						exit
					end
					
					current_file.instance_variable_set('@'+field_name, value)
					put(files_endpoint,current_file)
				else									#For regular non-built in fields
					data = {:id => current_field.id, :values => [value.to_s]}
					put(files_endpoint,data)
					
				end

			elsif current_field.field_display_type == 'boolean'

				#validate value
				unless ALLOWED_BOOLEAN_FIELD_OPTIONS.include?(value.to_s.strip)
					puts "ERROR: Invalid value #{value.inspect} for \"On/Off Switch\" field type.\n" +
						  "Acceptable Values => #{ALLOWED_BOOLEAN_FIELD_OPTIONS.inspect}"
					return false
				end
				
				
				#Interpret input
				#Even indicies in the field options array are On and Odd indicies are Off
				bool_val = ""
				if ALLOWED_BOOLEAN_FIELD_OPTIONS.find_index(value.to_s.strip).even?
					bool_val = "1"
				elsif ALLOWED_BOOLEAN_FIELD_OPTIONS.find_index(value.to_s.strip).odd?
					bool_val = "0"
				end

				#Prep the endpoint
				files_endpoint =  URI.parse(@uri + '/Files')

				current_file.fields.each do |obj| 
					if obj.id == current_field.id
						obj.values[0] = bool_val
					end
					
				end
				#udatte current variable for verbose statement
				current_value = bool_val
				#Actually do the update
				put(files_endpoint,current_file)
			else
				warn "Error: The field specified does not have a valid field_display_type." +
					 "Value provided => #{field.field_display_type.inspect}"
			end

			if @verbose
				puts "Setting value: \"#{current_value}\" to \"#{current_field.name}\" field " +
					 "for file => #{current_file.filename}"
			end
		end

		# Add data to ANY Project field (built-in or custom).
		#
		# @param project [Projects Object] (Required)
		# @param field [Fields Object] (Required)
		# @param value [String, Integer, Float] (Required)
		# @return [JSON object] HTTP response JSON object.
		#
		# @example rest_client.project_add_field_data(projects_object,fields_object,'data to be inserted')
		def project_add_field_data(project=nil,field=nil,value=nil)

			#validate class types
			unless project.is_a?(Projects) || (project.is_a?(String) && (project.to_i != 0)) || project.is_a?(Integer)
				warn "Argument Error: Invalid type for first argument in \"project_add_field_data\" method.\n" +
					 "\tExpected Single Projects object, a Numeric string or Integer for a Project id\n" +
					 "\tInstead got => #{project.inspect}"
				return			
			end 

			unless field.is_a?(Fields) ||  (field.is_a?(String) && (field.to_i != 0)) || field.is_a?(Integer)
				warn "Argument Error: Invalid type for second argument in \"project_add_field_data\" method.\n" +
					 "\tExpected Single Projects object, Numeric string, or Integer for Projects id.\n" +
					 "\tInstead got => #{field.inspect}"
				return			
			end

			unless value.is_a?(String) || value.is_a?(Integer)
				warn "Argument Error: Invalid type for third argument in \"project_add_field_data\" method.\n" +
					 "\tExpected a String or an Integer.\n" +
					 "\tInstead got => #{value.inspect}"
				return			
			end

			#NOTE: Date fields use the mm-dd-yyyy format
			current_project = nil
			current_field   = nil
			current_value	= value.to_s.strip

			project_class  = project.class.to_s
			field_class    = field.class.to_s

			#set up objects
			if project_class == 'Projects'
				current_project = project
			elsif project_class == 'String' || project_class == 'Integer' 
				#retrieve Projects object matching id provided
				uri = URI.parse(@uri + "/Projects")
				option = RestOptions.new
				option.add_option("id",project.to_s)
				current_project = get(uri,option).first
				unless current_project
					warn "ERROR: Could not find Project with matching id of \"#{project.to_s}\"...Exiting"
					return
				end
			else
				warn "Unknown Error retrieving project. Exiting."
				return
			end

			if field_class == 'Fields'
				current_field = field
			elsif field_class == 'String' || field_class == 'Integer'
				uri = URI.parse(@uri + "/Fields")
				option = RestOptions.new
				option.add_option("id",field.to_s)
				current_field = get(uri,option).first
				unless current_field
					warn "ERROR: Could not find Field with matching id of \"#{field.to_s}\"\n" +
						 "=> Hint: It either doesn't exist or it's disabled."
					return false
				end
				unless current_field.field_type == "project"
					warn "ERROR: Expected a Project field. The field provided is a \"#{current_field.field_type}\" field."
					return false
				end		
			else
				warn "Unknown Error retrieving field. Exiting."
				return
			end

			#Prep endpoint shortcut to be used for update
			projects_endpoint = URI.parse(@uri + "/Projects/#{current_project.id}/Fields")

			#Check the field type -> if its option or fixed suggestion we must make the option
			#available first before we can apply it to the Files resource
			if RESTRICTED_LIST_FIELD_TYPES.include?(current_field.field_display_type)
				
				lookup_string_endpoint = URI.parse(@uri + "/Fields/#{current_field.id}/FieldLookupStrings")

				#Grab all the available FieldLookupStrings for the specified Fields resource
				field_lookup_strings = get(lookup_string_endpoint)

				#check if the value in the third argument is currently an available option for the field
				lookup_string_exists = field_lookup_strings.find { |item| item.value == value }

				#add the option to the restricted field first if it's not there, otherwise you get a 400 bad 
				#request error saying that it couldn't find the string value for the restricted field specified 
				#when making a PUT request on the PROJECTS resource you are currently working on
				unless lookup_string_exists
					data = {:value => value}
					response = post(lookup_string_endpoint,data)
					return unless response.kind_of? Net::HTTPSuccess
				end

				#Now that we know the option is available, we can update the Projects 
				#NOUN we are currently working with using a PUT request
				data = {:id => current_field.id, :values => [value.to_s]}
				put(projects_endpoint,data)

				if @verbose
					puts "Adding value: \"#{value}\" to \"#{current_field.name}\" field" +
						 "for project => #{current_project.code} - #{current_project.name}"
				end


			elsif current_field.field_display_type == "date"
				#make sure we get the right date format
				#Accepts mm-dd-yyyy, mm-dd-yy, mm/dd/yyyy, mm/dd/yy
				date_regex = Regexp::new('((\d{2}-\d{2}-(\d{4}|\d{2}))|(\d{2}\/\d{2}\/(\d{4}|\d{2})))')
				unless (value =~ date_regex) == 0
					warn "ERROR: Invalid date format. Expected => \"mm-dd-yyyy\" or \"mm-dd-yy\""
					return
				end

				value.gsub!('/','-')
				date_arr = value.split('-') #convert date string to array for easy manipulation

				if date_arr.last.length == 2  #convert mm-dd-yy to mm-dd-yyyy format
					four_digit_year = '20' + date_arr.last

					date_arr[-1] = four_digit_year
				end
				#convert date to 14 digit unix time stamp
				value = date_arr[-1] + date_arr[-3] + date_arr[-2] + '000000'

				#Apply the date to our current Files resource
				data = {:id => current_field.id, :values => [value.to_s]}
				put(projects_endpoint,data) #Make the update

				
			elsif NORMAL_FIELD_TYPES.include?(current_field.field_display_type) #For regular fields
				#some fields are built into Projects so they can't be inserted into
				#the Projects nested fields resource. We get around this by using the
				#name of the field object to access the corresponding built-in field attribute
				#inside the Projects object.
				
				if current_field.built_in.to_s == "1"  #For built in fields
					projects_endpoint =  URI.parse(@uri + '/Projects') #change endpoint bc field is builtin
					field_name = current_field.name.downcase.gsub(' ','_')
					
					unless current_project.instance_variable_defined?('@'+field_name)
						warn "ERROR: The specified attirbute \"#{field_name}\" does not" + 
						     " exist in the Project. Exiting."
						exit
					end
					#update the project
					current_project.instance_variable_set('@'+field_name, value)
					#Make the update request
					put(projects_endpoint,current_project)                 

				else														#For regular non-built in fields
					data = {:id => current_field.id, :values => [value.to_s]}
					put(projects_endpoint,data)
				end
			elsif current_field.field_display_type == 'boolean'

				#validate value
				unless ALLOWED_BOOLEAN_FIELD_OPTIONS.include?(value.to_s.strip)
					puts "Error: Invalid value #{value.inspect} for \"On/Off Switch\" field type.\n" +
						  "Acceptable Values => #{ALLOWED_BOOLEAN_FIELD_OPTIONS.inspect}"
					return false
				end
				
				#Interpret input
				#Even indicies in the field options array are On and Odd indicies are Off
				bool_val = ""
				if ALLOWED_BOOLEAN_FIELD_OPTIONS.find_index(value.to_s.strip).even?
					bool_val = "1"
				elsif ALLOWED_BOOLEAN_FIELD_OPTIONS.find_index(value.to_s.strip).odd?
					bool_val = "0"
				end
				
				#Update the object
				projects_endpoint =  URI.parse(@uri + '/Projects')

				current_project.fields.each do |obj| 
					if obj.id == current_field.id
						obj.values[0] = bool_val
					end
					#obj
				end
				
				#Update current value variable for @verbose statement below
				current_value = bool_val

				#Acutally perform the update request
				put(projects_endpoint,current_project)
			else
				warn "Error: The field specified does not have a valid field_display_type." +
					 "Value provided => #{field.field_display_type.inspect}"
			end

			if @verbose
				puts "Setting value: \"#{current_value}\" to \"#{current_field.name}\" field " +
					 "for project => #{current_project.code} - #{current_project.name}"
			end
		end

	end

	def file_create_keywords_from_field_by_album(scope=nil, keyword_category=nil ,field=nil, batch_size=100, field_separator=';')
		#TO DO:
		#1. Validate input: scope => Category, Project, Album | field | batch_size
		unless scope.is_a?(Categories) || scope.is_a?(Projects) || scope.is_a?(Albums)
			abort("Argument Error: Expected a Categories, Projects, or Albums object for the first argument in #{__callee__}" +
					"\n\tIntead got #{scope.class}")
		end

		unless keyword_category.is_a?(KeywordCategories)
			abort("Argument Error: Expected a KeywordCategories object for the second argument in #{__callee__}." +
					"\n\tIntead got #{field.class}")
		end

		unless field.is_a?(Fields)
			abort("Argument Error: Expected a Fields object for the third argument in #{__callee__}." +
					"\n\tIntead got #{field.class}")
		end

		unless batch_size.to_i > 0
			abort("Argument Error: Expected a non zero value for the fourth argument \"batch size\" in #{__callee__}." +
					"\n\tInstead got #{batch_size.inspect}.")
		end

		unless field_separator.is_a?(String)
			abort("Argument Error: Expected a string value for the fifth argument \"field_separator\" in #{__callee__}." +
					"\n\tInstead got #{field_separator.class}.")
		end

		
		category_found   = nil
		project_found    = nil
		album_found      = nil
		total_file_count = nil
		file_id_array    = nil

		operating_scope  = nil
		op = RestOptions.new

		#2. Check if the category, project, or album exists and get the total file count
		if scope.is_a?(Categories)
			operating_scope = 'category'
			op.add_option('id', scope.id)
			category_found = get_categories(op).first
			abort("Error: Category id #{scope.id} not found in OpenAsset. Aborting") unless category_found
			op.clear
			op.add_option('category_id', scope.id)
			total_file_count = get_count(Files.new, op)
			op.clear
		elsif scope.is_a?(Projects)
			operating_scope = 'project'
			op.add_option('id', scope.id)
			project_found = get_projects(op).first
			abort("Error: Project id #{scope.id} not found in OpenAsset. Aborting")  unless project_found
			op.clear
			op.add_option('project_id', scope.id)
			total_file_count = get_count(Files.new, op)
			op.clear
		elsif scope.is_a?(Albums)
			operating_scope = 'album'
			op.add_option('id', scope.id)
			album_found = get_albums(op).first
			abort("Error: Album id #{scope.id} not found in OpenAsset. Aborting")    unless album_found
			file_id_array = album_found.files
			total_file_count  = file_id_array.length
			op.clear
		end

		#3. Check if field exists, if it's built-in or custom, and validate that it is a file field
		op.add_option('id',field.id)
		source_field_found = get_fields(op).first
		op.clear
		abort("Error: Field id #{field.id} not found in OpenAsset. Aborting") unless source_field_found.empty?
		abort("Error: Field is not an image field. Aborting") unless source_field_found.field_type == 'image'

		builtin = (source_field_found.built_in == '1') ? true : false
		
		#4. check if the keyword category exists, Make sure it belongs to the category specified
		op.add_option('id',keyword_category.id)
		keyword_category_found = get_keyword_categories(op).first
		op.clear
		if keyword_category_found.empty?
			abort("Error: Keyword Category #{keyword_category_found.name} id => #{keyword_category_found.id} not found in OpenAsset. Aborting")
		elsif keyword_category_found.category_id.to_i != scope.id.to_i

        # TO DO: FINISH THIS

		end

		# Verify all images in the album are from the same same category

		

		#6. Get all file keywords in the specified keyword category
		op.add_option('keyword_category_id', keyword_category.id)
		op.add_option('limit', '0')
		existing_keywords = get_keywords(op)
		op.clear

		#7. Calculate number of requests needed based on specified batch_size
		iterations = 0
		if total_file_count % batch_size == 0
			iterations = total_file_count / batch_size
		else
			iterations = total_file_count / batch_size + 1  #we'll need one more iteration to grab remaining
		end

		offset = 0
		limit  = batch_size.to_i
		#8. Create update loop using iteration limit and batch size
		iterations.times do

			op.add_option('offset', offset)
			op.add_option('limit', limit)

			if scope.is_a?(Categories)
				op.add('category_id', scope.id)
			elsif scope.is_a?(Projects)
				op.add('project_id', scope.id)
			elsif scope.is_a?(Albums)
				op.add('id', file_id_array.join)
			end

			#Get files for current batch
			files = get_files(op)
			op.clear

			keywords_to_create = []

			# Iterate through the files and find the keywords that need to be created
			files.each do |file|
				
				item_keywords = file.keywords
				 
				item_fields   = file.fields

				# Look for the field id in the nested fields attribute
				field_obj_found = item_fields.find { |f| f.id == field.id }

				if field_obj_found && (field_obj_found.values.first != '' || field_obj_found.values.first != nil)
					# split the string using the specified separator
					keywords_to_append = field_obj_found.values.first.split(field_separator)
					keywords_to_append.each do |val|

						# Trim the value
						val = val.strip

						# Check if the value exists in existing keywords
						keyword_found_in_existing = existing_keywords.find { |k| k.name == val }

						if keyword_found_in_existing
							# Check if the file is already tagged with that keyword
							already_tagged = item_keywords.find { |k| k.id == keyword_found_in_existing.id }
							unless already_tagged
								# Tag the file with the keyword
								file.keywords.push(NestedKeywordItems.new(keyword_found_in_existing.id))
							end	
						else
							# Insert into keywords_to_create array
							keywords_to_create.push(Keywords.new(keyword_category.id,val))
						end
						
					end
				end
			end

			# Remove dupes, Create the keywords for the current batch and set the generate objects flag to true.
			# Next, append the returned keyword objects to the existing keywords array
			unless keywords_to_create.empty?
				keywords_to_create.uniq! { |item| item.name }
				new_keywords = create_keywords(keywords_to_create, true)


				unless new_keywords.is_a?(Array) && !new_keywords.empty?
					existing_keywords.push(new_keywords)
				else
					Validator::process_http_response(new_keywords,@verbose,'Keywords','POST')
					abort("An error occured creating keywords in #{__callee__}")
				end
			end

			# Loop though the files again and tag them with the newly created keywords.
			files.each do | file |
				current_item_keywords = file.keywords
				current_item_fields   = file.fields

				# Check if the field has data in it
				field_found = current_item_fields.find { |nested_field_obj| nested_field_obj.id.to_s == field.id.to_s }

				if field_found
					data = field_found.values.first
					unless data == nil || data == ''
						keywords = data.split(field_separator)
						keywords.each do |value|
							#check if the string already exists as a keyword
							keyword_obj = existing_keywords.find { |item| item.name == value.strip }

							#check if current file is already tagged
							already_tagged = current_item_keywords.find { |item| item.id.to_s == keyword_obj.id.to_s}

							# Tag the file
							file.keywords.push(keyword_obj) unless already_tagged

						end
					end
				end
			end

			# Use another loop to control the number of times we retry the request in case it fails
			#9. Perform the update => 3 tries MAX with 5,10,15  second waits between retries respectively
			res = nil
			attempts = 0
			loop do

				attempts += 1

				# This code executes if the web server hangs or takes too long 
				# to respond after the first update is performed => Possible cause can be too large a batch size
				if attempts == 4
					Validator::process_http_response(res,@verbose,'Files','PUT')
					abort("Max Number of attempts (3) reached!\nThe web server may have taken too long to respond." +
						   " Try adjusting the batch size.")
				end

				#check if the server is responding (This is a HEAD request)
				server_test = get_count(Files.new)

				if server_test.is_a? Net::HTTPSuccess

					res = update_files(files)

					if res.kind_of? Net::HTTPSuccess
						offset += limit
						puts "Successfully updated #{offset.inspect} files."
						break
					else
						Validator::process_http_response(res,@verbose,'Files','PUT')
						abort
					end

				else

					sleep(5 * attempts)

				end
			end
			
		end 

	end

	def create_file_keywords_from_field_data_by_category(category=nil,target_keyword_category=nil,source_field=nil,batch_size=100,field_separator=';')
	
		#1. Validate input:
		op = RestOptions.new

		category_found              = nil
		file_keyword_category_found = nil
		source_field_found          = nil

		if category.is_a?(Categories)
			op.add_option('id',category.id)
			category_found = get_categories(op).first
			abort("Error: Category id #{category.id} not found in OpenAsset. Aborting") unless category_found
		elsif (category.is_a?(String) && category.to_i > 0) || category.is_a?(Integer)
			op.add_option('id',category)
			category_found = get_categories(op).first
			abort("Error: Category id #{category} not found in OpenAsset. Aborting") unless category_found
		elsif category.is_a?(String)
			op.add_option('name',category)
			category_found = get_categories(op).first
			abort("Error: Category named #{category} not found in OpenAsset. Aborting") unless category_found
		else
			abort("Argument Error: Expected a Categories object, Category name, or Category id for the first argument in #{__callee__}" +
					"\n\tIntead got #{category.inspect}")
		end

		op.clear

		if target_keyword_category.is_a?(KeywordCategories)
			op.add_option('id',target_keyword_category.id)
			file_keyword_category_found = get_keyword_categories(op).first
			abort("Error: File Keyword Category id #{target_keyword_category.id} not found in OpenAsset. Aborting") unless file_keyword_category_found
		elsif (target_kwyword_category.is_a?(String) && target_kwyword_category.to_i > 0) || target_kwyword_category.is_a?(Integer)
			op.add_option('id',target_keyword_category)
			file_keyword_category_found = get_keyword_categories(op).first
			abort("Error: File Keyword Category id #{target_keyword_category} not found in OpenAsset. Aborting") unless file_keyword_category_found
		elsif target_kwyword_category.is_a?(String)
			op.add_option('name',target_keyword_category)
			file_keyword_category_found = get_keyword_categories(op).first
			abort("Error: File Keyword Category named #{target_keyword_category} not found in OpenAsset. Aborting") unless file_keyword_category_found
		else
			abort("Argument Error: Expected a KeywordCategories object, File Keyword Category name, or File Keyword Category id for the second argument in #{__callee__}" +
					"\n\tIntead got #{target_keyword_category.inspect}")
		end

		op.clear

		if source_field.is_a?(Fields)
			op.add_option('id',source_field.id)
			source_field_found = get_fields(op).first
			abort("Error: Field id #{source_field.id} not found in OpenAsset. Aborting") unless source_field_found
		elsif (source_field.is_a?(String) && source_field.to_i > 0) || source_field.is_a?(Integer)
			op.add_option('id',source_field)
			source_field_found = get_fields(op).first
			abort("Error: Field id #{source_field} not found in OpenAsset. Aborting") unless source_field_found
		elsif source_field.is_a?(String)
			op.add_option('name',source_field)
			source_field_found = get_fields(op).first
			abort("Error: Field named #{source_field} not found in OpenAsset. Aborting") unless source_field_found
		else
			abort("Argument Error: Expected a Fields object, File Field name, or File Field id for the third argument in #{__callee__}" +
					"\n\tIntead got #{target_keyword_category.inspect}")
		end

		op.clear

		unless batch_size.to_i > 0
			abort("Argument Error: Expected a non zero numeric value for the fourth argument \"batch size\" in #{__callee__}." +
					"\n\tInstead got #{batch_size.inspect}.")
		end

		unless field_separator.is_a?(String)
			abort("Argument Error: Expected a string value for the fifth argument \"field_separator\" in #{__callee__}." +
					"\n\tInstead got #{field_separator.class}.")
		end

		#2. Get total file count
		op.add_option('category_id', category_found.id)
		total_file_count = get_count(Files.new, op)
		op.clear
		
		abort("Error: Field is not an image field. Aborting") unless source_field_found.field_type == 'image'

		#3. Check field type
		builtin = (source_field_found.built_in == '1') ? true : false

		#4. Get all file keywords in the specified keyword category
		op.add_option('keyword_category_id', file_keyword_category_found.id)
		op.add_option('limit', '0')
		existing_keywords = get_keywords(op)
		op.clear

		#5. Calculate number of requests needed based on specified batch_size
		iterations = 0
		if total_file_count % batch_size == 0
			iterations = total_file_count / batch_size
		else
			iterations = total_file_count / batch_size + 1  #we'll need one more iteration to grab remaining
		end

		offset = 0
		limit  = batch_size.to_i
		total_files_updated = 0

		#6. Create update loop using iteration limit and batch size
		iterations.times do

			op.add_option('offset', offset)
			op.add_option('limit', limit)
			op.add('category_id', category_found.id)
			
			#7. Get current batch of files => body length used to track total files updated
			files = get_files(op)
			op.clear

			keywords_to_create = []

			#8. Iterate through the files and find the keywords that need to be created
			files.each do |file|
				
				field_data            = nil
				field_obj_found       = nil

				#9. Look for the field id in the nested fields attribute or get the string value if it's builtin
				if builtin
					field_data = file.instance_variable_get("@#{source_field_found.name.downcase}")
					next if field_data.nil? || field_data == ''
				else
					field_obj_found = file.fields.find { |f| f.id == field.id }
					if field_obj_found.nil? || field_obj_found.values.first.nil? || field_obj_found.values.first == ''
						next
					end
					field_data = field_obj_found.values.first
				end

				#10. split the string using the specified separator and remove empty strings
				keywords_to_append = field_data.split(field_separator).reject { |val| val.to_s.empty? }
				keywords_to_append.each do |val|

					#11. remove leading and trailing white space
					val = val.strip

					#12. Check if the value exists in existing keywords
					keyword_found_in_existing = existing_keywords.find { |k| k.name.downcase == val.downcase }

					unless keyword_found_in_existing
						#13. Insert into keywords_to_create array
						keywords_to_create.push(Keywords.new(keyword_category.id, val.capitalize))
					end
					
				end
	
			end

			#14. Remove duplicates, 
			unless keywords_to_create.empty?
				keywords_to_create.uniq! { |item| item.name }
				#15. Create the keywords for the current batch and set the generate objects flag to true.
				new_keywords = create_keywords(keywords_to_create, true)

				#16. Append the returned keyword objects to the existing keywords array
				unless new_keywords.is_a?(Array) && !new_keywords.empty?
					existing_keywords.push(new_keywords)
				else
					# Process the response to find what the error was
					Validator::process_http_response(new_keywords,@verbose,'Keywords','POST')
					abort("An error occured creating keywords in #{__callee__}")
				end
			end

			#17. Loop though the files again and tag them with the newly created keywords.
			files.each do | file |

				field_found = nil
			
				# Check if the field has data in it
				field_found = current_item_fields.find do |nested_field_obj| 
					nested_field_obj.id.to_s == source_field_found.id.to_s 
				end

				if field_found
					data = field_found.values.first
					unless data == nil || data == ''
						keywords = data.split(field_separator)
						keywords.each do |value|

							value = value.strip
							#find the string in existing keywords
							keyword_obj = existing_keywords.find { |item| item.name.downcase == value.downcase }

							#check if current file is already tagged
							already_tagged = file.keywords.find { |item| item.id.to_s == keyword_obj.id.to_s}

							# Tag the file
							file.keywords.push(NestedKeywordItems.new(keyword_obj.id)) unless already_tagged

						end
					end
				end
			end

			# Use another loop to control the number of times we retry the request in case it fails
			#18. Perform the update => 3 tries MAX with 5,10,15  second waits between retries respectively
			res = nil
			attempts = 0
			
			loop do

				attempts += 1

				# This code executes if the web server hangs or takes too long 
				# to respond after the first update is performed => Possible cause can be too large a batch size
				if attempts == 4
					Validator::process_http_response(res,@verbose,'Files','PUT')
					abort("Max Number of attempts (3) reached!\nThe web server may have taken too long to respond." +
						   " Try adjusting the batch size.")
				end

				#check if the server is responding (This is a HEAD request)
				server_test = get_count(Files.new)

				if server_test.is_a? Net::HTTPSuccess

					res = update_files(files)

					if res.kind_of? Net::HTTPSuccess
						offset += limit
						total_files_updated += files.length
						puts "Successfully updated #{total_files_updated.inspect} files."
						break
					else
						Validator::process_http_response(res,@verbose,'Files','PUT')
						abort
					end
				else
					sleep(5 * attempts)
				end
			end	
		end 
	end

	def create_file_keywords_from_field_data_by_project(project=nil,target_keyword_category=nil,field=nil,batch_size=100,field_separator=';')
		
		op = RestOptions.new

		project_found               = nil
		file_keyword_category_found = nil
		source_field_found          = nil
		
		
		#1. Validate input
		if project.is_a?(Projects)
			op.add_option('id',project.id)
			project_found = get_projects(op).first
			abort("Error: Project id #{project.id} not found in OpenAsset. Aborting") unless project_found
		elsif (project.is_a?(String) && project.to_i > 0) || project.is_a?(Integer)
			op.add_option('id',project)
			project_found = get_projects(op).first
			abort("Error: Project id #{project} not found in OpenAsset. Aborting") unless project_found
		elsif project.is_a?(String)
			op.add_option('name',project)
			project_found = get_projects(op).first
			abort("Error: Project named #{project} not found in OpenAsset. Aborting") unless project_found
		else
			abort("Argument Error: Expected a Projects object, Project name, or Project id for the second argument in #{__callee__}" +
					"\n\tIntead got #{project.inspect}")
		end

		op.clear

		# # ISSUE:    THERE IS NO DIRECT WAY OF VERIFYING THAT A PROJECT IS UNDER THE SPECIFIED CATEGORY
		# # SOLUTION: GET A FILE USING THE PROJECT ID SPECIFIED AND CHECK IF ITS CATEGORY ID MATCHES THE ONE SPECIFIED

		# op.add_option('project_id',project_found.id)
		# project_to_category_test = get_files(op).first

		# op.clear

		# if project_to_category_test.nil?
		# 	warn "Error: Project #{project_found.name} with id => #{project_found.id} is empty."
		# 	return
		# elsif project_to_category_test.category_id != category_found.id
		# 	# Tell the user there is a mismatch between the category and project specified.
		# 	error = "Error: The Project #{project_found.name} with id => #{project_found.id} " +
		# 		    "does NOT belong to the #{category_found.name} category."

		# 	if @verbose
		# 		op.add_option('id',project_to_category_test.category_id)
		# 		wrong_category = get_categories(op).first
		# 		error += "\nIt belongs to the #{wrong_category.name} category."
		# 	end
		# 	abort(error)
		# end

		op.clear

		if target_keyword_category.is_a?(KeywordCategories)
			op.add_option('id',target_keyword_category.id)
			file_keyword_category_found = get_keyword_categories(op).first
			abort("Error: File Keyword Category id #{target_keyword_category.id} not found in OpenAsset. Aborting") unless file_keyword_category_found
		elsif (target_keyword_category.is_a?(String) && target_keyword_category.to_i > 0) || target_keyword_category.is_a?(Integer)
			op.add_option('id',target_keyword_category)
			file_keyword_category_found = get_keyword_categories(op).first
			abort("Error: File Keyword Category id #{target_keyword_category} not found in OpenAsset. Aborting") unless file_keyword_category_found
		elsif target_keyword_category.is_a?(String)
			op.add_option('name',target_keyword_category)
			file_keyword_category_found = get_keyword_categories(op).first
			abort("Error: File Keyword Category named #{target_keyword_category} not found in OpenAsset. Aborting") unless file_keyword_category_found
		else
			abort("Argument Error: Expected a KeywordCategories object, File Keyword Category name, or File Keyword Category id for the second argument in #{__callee__}" +
					"\n\tIntead got #{target_keyword_category.inspect}")
		end

		op.clear

		if source_field.is_a?(Fields)
			op.add_option('id',source_field.id)
			source_field_found = get_fields(op).first
			abort("Error: Field id #{source_field.id} not found in OpenAsset. Aborting") unless source_field_found
		elsif (source_field.is_a?(String) && source_field.to_i > 0) || source_field.is_a?(Integer)
			op.add_option('id',source_field)
			source_field_found = get_fields(op).first
			abort("Error: Field id #{source_field} not found in OpenAsset. Aborting") unless source_field_found
		elsif source_field.is_a?(String)
			op.add_option('name',source_field)
			source_field_found = get_fields(op).first
			abort("Error: Field named #{source_field} not found in OpenAsset. Aborting") unless source_field_found
		else
			abort("Argument Error: Expected a Fields object, File Field name, or File Field id for the third argument in #{__callee__}" +
					"\n\tIntead got #{target_keyword_category.inspect}")
		end

		abort("Error: Field is not an image field. Aborting") unless source_field_found.field_type == 'image'
		
		op.clear

		unless batch_size.to_i > 0
			abort("Argument Error: Expected a non zero numeric value for the fourth argument \"batch size\" in #{__callee__}." +
					"\n\tInstead got #{batch_size.inspect}.")
		end

		unless field_separator.is_a?(String)
			abort("Argument Error: Expected a string value for the fifth argument \"field_separator\" in #{__callee__}." +
					"\n\tInstead got #{field_separator.class}.")
		end
		
		# Get all the categories associated with the files in the project then using the target_keyword_category,  
		# create the file keyword category in all the system categories that don't have them

		# Capture associated system categories
		op.add_option('limit','0')
		op.add_option('project_id',project_found.id)
		op.add_option('displayFields','category_id')
		file_category_ids_contained_in_project = get_file(op).uniq { |obj| obj.category_id }
		file_category_ids_contained_in_project = file_category_ids_contained_in_project.map { |obj| obj.category_id } # We just want the ids
		op.clear

		keyword_categories = []
		keyword_categories << file_keyword_category_found

		# Create the keyword category in all associated categories => remove the category that the target_keyword_category
		# belongs to because it already exists
		file_cat_ids = file_category_ids_contained_in_project.reject { |val| val == file_keyword_category_found.category_id }

		# Now loop throught the file categories, create the needed keyword category, and store an association for referencing below
		file_cat_ids.each do |id|
			obj = KeywordCategories.new(file_keyword_category_found.name, id)
			kwd_cat_obj = create_keyword_categories(obj, true).first
			abort("Error creating keyword category in #{__callee__}") unless kwd_cat_obj
			keyword_categories.push(kwd_cat_obj)
		end

		#2. Get total file count
		op.add_option('category_id', project.id)
		total_file_count = get_count(Files.new, op)
		op.clear

		#3. Check field type
		builtin = (source_field_found.built_in == '1') ? true : false

		#4. Get all file keywords in the specified keyword category for all the file categories found in the project
		query_ids = keyword_categories.map { |item| item.id }.join(',')
		
		op.add_option('keyword_category_id', query_ids)
		op.add_option('limit', '0')

		existing_keywords = get_keywords(op)
		op.clear

		keyword_store = Hash.new{ |h, k| h[k] = Hash.new(&h.default_proc) }
		
		#5. Calculate number of requests needed based on specified batch_size
		iterations = 0
		if total_file_count % batch_size == 0
			iterations = total_file_count / batch_size
		else
			iterations = total_file_count / batch_size + 1  #we'll need one more iteration to grab remaining
		end

		offset = 0
		limit  = batch_size.to_i
		total_files_updated = 0

		#6. Create update loop using iteration limit and batch size
		iterations.times do

			op.add_option('offset', offset)
			op.add_option('limit', limit)
			op.add('project_id', project_found.id)
			
			#7. Get current batch of files => body length used to track total files updated
			files = get_files(op)
			op.clear

			keywords_to_create = []

			#8. Iterate through the files and find the keywords that need to be created
			files.each do |file|
				
				field_data      = nil
				field_obj_found = nil

				#9. Look for the field id in the nested fields attribute or get the string value if it's builtin
				if builtin
					field_data = file.instance_variable_get("@#{source_field_found.name.downcase}")
					next if field_data.nil? || field_data == ''
				else
					field_obj_found = file.fields.find { |f| f.id == source_field_found.id }
					if field_obj_found.nil? || field_obj_found.values.first.nil? || field_obj_found.values.first == ''
						next
					end
					field_data = field_obj_found.values.first
				end

				#10. split the string using the specified separator and remove empty strings
				keywords_to_append = field_data.split(field_separator).reject { |val| val.to_s.empty? }
				keywords_to_append.each do |val|

					#11. remove leading and trailing white space
					val = val.strip

					#12. Check if the value exists in existing keywords
					keyword_found_in_existing = existing_keywords.find do |k|
						# Match the existing keywords check by the name of the value and the category
						# id of the current file to establish the the link between the two
						k.name.downcase == val.downcase && file.category_id == k.keyword_category_id
					end

					unless keyword_found_in_existing
						# find  keyword cat id and system cat id of file
						obj = keyword_categories.find { |item| item.category_id == file.category_id }
						#13. Insert into keywords_to_create array
						keywords_to_create.push(Keywords.new(.id, val.capitalize))
					end
					
				end
	
			end

			#14. Remove duplicates, 
			unless keywords_to_create.empty?
				keywords_to_create.uniq! { |item| item.name }
				#15. Create the keywords for the current batch and set the generate objects flag to true.
				new_keywords = create_keywords(keywords_to_create, true)

				#16. Append the returned keyword objects to the existing keywords array
				unless new_keywords.is_a?(Array) && !new_keywords.empty?
					existing_keywords.push(new_keywords)
				else
					# Process the response to find what the error was
					Validator::process_http_response(new_keywords,@verbose,'Keywords','POST')
					abort("An error occured creating keywords in #{__callee__}")
				end
			end

			#17. Loop though the files again and tag them with the newly created keywords. Faster than making individual requests
			files.each do | file |

				field_found = nil

				# Check if the field has data in it
				field_found = file.fields.find do |nested_field_obj| 
					nested_field_obj.id.to_s == source_field_found.id.to_s 
				end

				if field_found
					data = field_found.values.first
					unless data == nil || data == ''
						keywords = data.split(field_separator)
						keywords.each do |value|

							value = value.strip
							#find the string in existing keywords
							keyword_obj = existing_keywords.find { |item| item.name.downcase == value.downcase }

							#check if current file is already tagged
							already_tagged = file.keywords.find { |item| item.id.to_s == keyword_obj.id.to_s}

							# Tag the file
							file.keywords.push(NestedKeywordItems.new(keyword_obj.id)) unless already_tagged

						end
					end
				end
			end

			# Use another loop to control the number of times we retry the request in case it fails
			#18. Perform the update => 3 tries MAX with 5,10,15  second waits between retries respectively
			res = nil
			attempts = 0
			
			loop do

				attempts += 1

				# This code executes if the web server hangs or takes too long 
				# to respond after the first update is performed => Possible cause can be too large a batch size
				if attempts == 4
					Validator::process_http_response(res,@verbose,'Files','PUT')
					abort("Max Number of attempts (3) reached!\nThe web server may have taken too long to respond." +
						   " Try adjusting the batch size.")
				end

				#check if the server is responding (This is a HEAD request)
				server_test = get_count(Files.new)

				if server_test.is_a? Net::HTTPSuccess

					res = update_files(files)

					if res.kind_of? Net::HTTPSuccess
						offset += limit
						total_files_updated += files.length
						puts "Successfully updated #{total_files_updated.inspect} files."
						break
					else
						Validator::process_http_response(res,@verbose,'Files','PUT')
						abort
					end
				else
					sleep(5 * attempts)
				end
			end	
		end 
	end

end

puts 'Syntax TEST Passed blah' 