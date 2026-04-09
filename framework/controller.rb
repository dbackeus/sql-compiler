class Controller
  VIEW_PATH = __dir__ + "/../app/views"

  def render(view_name, locals = {})
    template_path = File.join(VIEW_PATH, resource_name, "#{view_name}.html.erb")
    template = ERB.new(File.read(template_path))
    template.result_with_hash(locals)
  end

  def resource_name
    self.class.name.delete_suffix("Controller").downcase
  end
end
