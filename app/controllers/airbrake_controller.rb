require 'hpricot'

class AirbrakeController < ApplicationController
  skip_before_filter :check_if_login_required
  before_filter :find_or_create_custom_fields

  unloadable
  
  def index
    redirect_to root_path unless request.post? && !params[:notice].nil?
    @notice = params[:notice]
    if (@notice['version'] != "2.0")
      logger.warn("Expected Airbrake notice version 2.0 but got #{@notice['version']}. You should consider filing an enhancement request or updating the plugin.")
    end

    restore_var_elements(request.body)
    
    redmine_params = YAML.load(@notice['api_key'])
    raise ArgumentError.new("Invalid API key #{Setting.mail_handler_api_key} != #{redmine_params[:api_key]}") unless Setting.mail_handler_api_key == redmine_params[:api_key]

    read_settings(redmine_params)

    subject = build_subject
    @issue = Issue.find_by_subject_and_project_id_and_tracker_id(subject, @settings[:project].id, @settings[:tracker].id, :order => 'id DESC')

    if @issue.nil?
      create_new_issue
    elsif @issue.custom_value_for(@environment_field.id).value == @notice['server_environment']['environment_name'] && @issue.custom_value_for(@application_field.id).value == redmine_params[:application]
      
      update_existing_issue
    else
      create_new_issue
    end
    
    render :layout => false
  end
  
  private

  # The automagic XML parsing by Rails ignores the text elements
  # This method replaces the garbled elements with new hashes
  def restore_var_elements(original_xml)
    return if @notice['request'].nil?
    
    doc = Hpricot::XML(request.body)
    
    unless @notice['request']['params'].nil?
      request_params = convert_var_elements(doc/'/notice/request/params/var')
      request_params.delete('action') # already known
      request_params.delete('controller') # already known    
      @notice['request']['params'] = request_params
    end
    
    unless @notice['request']['cgi_data'].nil?
      cgi_data = convert_var_elements(doc/'notice/request/cgi-data/var')
      @notice['request']['cgi_data'] = cgi_data
    end
    
    unless @notice['request']['session'].nil?
      session_vars = convert_var_elements(doc/'/notice/request/session/var')
      @notice['request']['session'] = session_vars
    end
  end
  
  def convert_var_elements(elements)
    result = {}
    elements.each do |elem|
      result[elem.attributes['key']] = elem.inner_text
    end
    result
  end
  
  def read_settings(params)
    project = Project.find_by_identifier(params[:project]) or raise ArgumentError.new("invalid project #{params[:project]}")
    @settings = {}
    @settings[:project] = project
    @settings[:tracker] = project.trackers.find_by_name(params[:tracker]) if params.has_key?(:tracker)
    # these are optional
    [:reopen_strategy, :fixed_version_id].each do |key|
      @settings[key] = params[key] if params.has_key?(key)
    end
    @settings[:priority] = IssuePriority.find_by_id(params[:priority]) if params.has_key?(:priority)
    @settings[:author] = User.find_by_login(params[:login]) if params.has_key?(:login)
    @settings[:category] = IssueCategory.find_by_name(params[:category]) if params.has_key?(:category)
    @settings[:assign_to] = User.find_by_login(params[:assigned_to]) if params.has_key?(:assigned_to)
    @settings[:application] = params[:application] if params.has_key?(:application)

    read_local_settings
    check_custom_field_assignments
  end
  
  def read_local_settings
    local_settings = AirbrakeServerProjectSettings.find_by_project_id(@settings[:project].id)
    return if local_settings.nil?
    [:author, :priority, :reopen_strategy, :tracker, :category, :assign_to, :fixed_version_id].each do |key|
      @settings[key] = local_settings.send(key.to_s) unless @settings.has_key?(key)
    end
  end
  
  def create_new_issue
    @issue = Issue.new
    @issue.author = @settings[:author]
    @issue.subject = build_subject
    @issue.tracker = @settings[:tracker]
    @issue.project = @settings[:project]
    @issue.category = @settings[:category]
    @issue.fixed_version_id = @settings[:fixed_version_id]
    @issue.assigned_to = @settings[:assign_to]
    @issue.priority = @settings[:priority] unless @settings[:priority].nil?
    @issue.description = render_to_string(:partial => 'issue_description')
    @issue.status = IssueStatus.default
    @issue.custom_values.build(:custom_field => @occurrences_field, :value => '1')
    @issue.custom_values.build(:custom_field => @last_occured_field, :value => Time.now.to_date.to_s )
    @issue.custom_values.build(:custom_field => @application_field, :value => @settings[:application])
    @issue.custom_values.build(:custom_field => @environment_field, :value => @notice['server_environment']['environment_name'])
    @issue.custom_values.build(:custom_field => @version_field, :value => @notice['server_environment']['app_version']) unless @notice['server_environment']['app_version'].nil?
    @issue.save!
  end
  
  def check_custom_field_assignments
    [@occurrences_field, @environment_field, @version_field].each do |field|
      @settings[:project].issue_custom_fields << field unless @settings[:project].issue_custom_fields.include?(field)
      @settings[:tracker].custom_fields << field unless @settings[:tracker].custom_fields.include?(field)
    end
  end
  
  def update_existing_issue

    number_occurrences = @issue.custom_value_for(@occurrences_field.id).value
    @issue.custom_field_values = { @occurrences_field.id => (number_occurrences.to_i+1).to_s, @last_occured_field.id => Time.now.to_date.to_s }

    if @issue.closed?
      @issue.status = IssueStatus.default
      environment_name = @notice['server_environment']['environment_name']
      journal = @issue.init_journal(@settings[:author], "h4. Issue reopened after happening again.Occurances was at #{number_occurrences.to_s}")
      journal.notes = render_to_string(:partial => 'issue_description')  # put in new call stack just in case it's relavant. the issue had closed after all.
      journal.save
    elsif number_occurrences % 10 == 0  
      journal = @issue.journals.new :version => @issue.journals.maximum(:version)+1
      journal.notes = journal.notes = render_to_string(:partial => 'issue_description')  # put in new call stack every now and again just in case it's relavant
      journal.save
    end

    @issue.save!
    begin
      @issue.touch  # forcing this as the above doesn't actually change the updated_on field all the time
    rescue
    end
  end
     
  def build_subject
    error_class = @notice['error']['class']
    # if there's only one line, it gets parsed into a hash instead of an array
    # the split is to remove [PROJECT_ROOT] etc... from within the begining of the file name makes it nicer when listing issues
    if @notice['error']['backtrace']['line'].is_a? Hash
      file = @notice['error']['backtrace']['line']['file'].split(']/').last
      line = @notice['error']['backtrace']['line']['number']
    else
      file = @notice['error']['backtrace']['line'].first()['file'].split(']/').last
      line = @notice['error']['backtrace']['line'].first()['number']
    end

    "[#{@settings[:application]}:#{@notice['server_environment']['environment_name']}] #{error_class} in #{file}:#{ line[([-200, line.length*-1].max)..-1] }"
  end
  
  def find_or_create_custom_fields
    @occurrences_field = IssueCustomField.find_or_initialize_by_name('# Occurrences')
    if @occurrences_field.new_record?
      @occurrences_field.attributes = {:field_format => 'int', :default_value => '1', :is_filter => true}
      @occurrences_field.save(false)
    end
    
    @last_occured_field = IssueCustomField.find_or_initialize_by_name('Last occurance')
    if @last_occured_field.new_record?
      @last_occured_field.attributes = {:field_format => 'date', :default_value => '', :is_filter => true}
      @last_occured_field.save(false)
    end

    @application_field = IssueCustomField.find_or_initialize_by_name('Application')
    if @application_field.new_record?
      @application_field.attributes = {:field_format => 'string', :default_value => '', :is_filter => true}
      @application_field.save(false)
    end

    @environment_field = IssueCustomField.find_or_initialize_by_name('Environment')
    if @environment_field.new_record?
      @environment_field.attributes = {:field_format => 'string', :default_value => 'production', :is_filter => true}
      @environment_field.save(false)
    end
    
    @version_field = IssueCustomField.find_or_initialize_by_name('Version')
    if @version_field.new_record?
      @version_field.attributes = {:field_format => 'string', :default_value => '', :is_filter => true}
      @version_field.save(false)
    end
  end
end
