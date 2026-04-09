require "erb"
require "prism"
require "set"

class StaticProjectionCompiler
  Loadsite = Struct.new(:key, :model_class, :query_kind, :columns, :unsafe, keyword_init: true)
  Binding = Struct.new(:loadsite_key, :model_class, :kind, keyword_init: true)

  def initialize(root: File.expand_path("..", __dir__), controller_paths: nil, view_path: nil)
    @root = root
    @controller_paths = Array(controller_paths || Dir.glob(File.join(root, "app/controllers/**/*.rb")).sort)
    @view_path = view_path || File.join(root, "app/views")
  end

  def compile
    loadsites = {}

    controller_paths.each do |controller_path|
      compile_controller(controller_path, loadsites)
    end

    loadsites.transform_values do |loadsite|
      next ProjectionRegistry::UNSAFE if loadsite.unsafe

      loadsite.model_class.attribute_names.select { |name| loadsite.columns.include?(name) }
    end
  end

  private

  attr_reader :controller_paths, :view_path

  def compile_controller(controller_path, loadsites)
    program = Prism.parse_file(controller_path).value
    each_node(program) do |node|
      next unless node.type == :class_node && node.body

      controller_name = node.constant_path.name.to_s
      next unless controller_name.end_with?("Controller")

      resource_name = controller_name.delete_suffix("Controller").downcase

      node.body.body.each do |child|
        next unless child.type == :def_node

        traverse(
          child,
          current_path: controller_path,
          resource_name:,
          bindings: {},
          loadsites:
        )
      end
    end
  end

  def traverse(node, current_path:, resource_name:, bindings:, loadsites:)
    case node.type
    when :statements_node
      node.body.to_a.each do |child|
        traverse(child, current_path:, resource_name:, bindings:, loadsites:)
      end
    when :local_variable_write_node
      assign_local(node.name, node.value, bindings:, current_path:, resource_name:, loadsites:)
    when :call_node
      handle_call(node, current_path:, resource_name:, bindings:, loadsites:)
    when :block_node
      traverse(node.body, current_path:, resource_name:, bindings: bindings.dup, loadsites:)
    else
      node.compact_child_nodes.each do |child|
        traverse(child, current_path:, resource_name:, bindings:, loadsites:)
      end
    end
  end

  def assign_local(name, value, bindings:, current_path:, resource_name:, loadsites:)
    previous_binding = bindings[name]
    new_binding = query_binding_for(value, current_path:, loadsites:)

    if previous_binding && previous_binding != new_binding
      mark_unsafe(previous_binding.loadsite_key, loadsites)
    end

    bindings.delete(name)
    bindings[name] = new_binding if new_binding

    traverse(value, current_path:, resource_name:, bindings:, loadsites:)
  end

  def handle_call(node, current_path:, resource_name:, bindings:, loadsites:)
    if attribute_read?(node, bindings)
      add_column(binding_for_expression(node.receiver, bindings).loadsite_key, node.name, loadsites)
      traverse_children(node, current_path:, resource_name:, bindings:, loadsites:, skip: [node.receiver])
      return
    end

    if collection_each?(node, bindings)
      collection_binding = binding_for_expression(node.receiver, bindings)
      block = node.block
      block_bindings = bindings.dup

      block_parameter_name(block)&.then do |parameter_name|
        block_bindings[parameter_name] = Binding.new(
          loadsite_key: collection_binding.loadsite_key,
          model_class: collection_binding.model_class,
          kind: :instance
        )
      end

      traverse(block.body, current_path:, resource_name:, bindings: block_bindings, loadsites:)
      traverse_arguments(node, current_path:, resource_name:, bindings:, loadsites:)
      return
    end

    if render_call?(node)
      analyze_render(node, current_path:, resource_name:, bindings:, loadsites:)
      traverse_arguments(node, current_path:, resource_name:, bindings:, loadsites:, skip_keyword_hash: true)
      return
    end

    if (binding = binding_for_expression(node.receiver, bindings))
      mark_unsafe(binding.loadsite_key, loadsites)
    end

    traverse_children(node, current_path:, resource_name:, bindings:, loadsites:)
  end

  def analyze_render(node, current_path:, resource_name:, bindings:, loadsites:)
    template_name = render_template_name(node)
    return unless template_name

    view_bindings = render_bindings(node, bindings:, loadsites:)
    return if view_bindings.empty?

    template_path = File.join(view_path, resource_name, "#{template_name}.html.erb")
    unless File.exist?(template_path)
      view_bindings.each_value { |binding| mark_unsafe(binding.loadsite_key, loadsites) }
      return
    end

    source = ERB.new(File.read(template_path)).src
    program = Prism.parse(source)
    view_bindings = view_bindings.transform_keys(&:to_sym)

    traverse(
      program.value,
      current_path: template_path,
      resource_name:,
      bindings: view_bindings,
      loadsites:
    )
  rescue StandardError
    view_bindings.each_value { |binding| mark_unsafe(binding.loadsite_key, loadsites) }
  end

  def render_bindings(node, bindings:, loadsites:)
    arguments = node.arguments
    return {} unless arguments

    keyword_hash = arguments.arguments.find { |argument| argument.type == :keyword_hash_node }
    return {} unless keyword_hash

    keyword_hash.elements.each_with_object({}) do |assoc, result|
      key = symbol_name(assoc.key)
      next unless key

      binding = binding_for_expression(unwrap_implicit(assoc.value), bindings)
      if binding
        result[key.to_sym] = binding
      else
        referenced_loadsites(assoc.value, bindings).each { |loadsite_key| mark_unsafe(loadsite_key, loadsites) }
      end
    end
  end

  def render_template_name(node)
    arguments = node.arguments
    return unless arguments

    first_argument = arguments.arguments.first
    first_argument&.type == :string_node ? first_argument.unescaped : nil
  end

  def query_binding_for(node, current_path:, loadsites:)
    call = unwrap_implicit(node)
    return unless call.type == :call_node

    model_class = model_class_for(call.receiver)
    return unless model_class

    kind = case call.name
    when :all then :collection
    when :find then :instance
    end
    return unless kind

    key = ProjectionRegistry.key_for(
      path: current_path,
      line: call.location.start_line,
      model_class:,
      query_kind: call.name
    )

    loadsites[key] ||= Loadsite.new(
      key:,
      model_class:,
      query_kind: call.name,
      columns: Set.new,
      unsafe: false
    )

    Binding.new(loadsite_key: key, model_class:, kind:)
  end

  def attribute_read?(node, bindings)
    binding = binding_for_expression(node.receiver, bindings)
    return false unless binding&.kind == :instance
    return false unless node.arguments.nil?

    binding.model_class.attribute_names.include?(node.name.to_s)
  end

  def collection_each?(node, bindings)
    binding = binding_for_expression(node.receiver, bindings)
    binding&.kind == :collection && node.name == :each && node.block
  end

  def binding_for_expression(node, bindings)
    return if node.nil?

    expression = unwrap_implicit(node)

    case expression.type
    when :local_variable_read_node
      bindings[expression.name]
    when :call_node
      if expression.receiver.nil? && expression.arguments.nil? && bindings.key?(expression.name)
        bindings[expression.name]
      end
    end
  end

  def referenced_loadsites(node, bindings, result = Set.new)
    return result if node.nil?

    if (binding = binding_for_expression(node, bindings))
      result << binding.loadsite_key
    end

    node.compact_child_nodes.each do |child|
      referenced_loadsites(child, bindings, result)
    end

    result
  end

  def add_column(loadsite_key, column_name, loadsites)
    loadsite = loadsites[loadsite_key]
    return if loadsite.nil? || loadsite.unsafe

    loadsite.columns << column_name.to_s
  end

  def mark_unsafe(loadsite_key, loadsites)
    loadsite = loadsites[loadsite_key]
    loadsite.unsafe = true if loadsite
  end

  def block_parameter_name(block)
    return unless block.parameters&.parameters

    block.parameters.parameters.requireds.first&.name
  end

  def model_class_for(node)
    constant = constant_name(node)
    return unless constant

    klass = Object.const_get(constant)
    klass if klass < Model
  rescue NameError
    nil
  end

  def constant_name(node)
    return unless node

    case node.type
    when :constant_read_node
      node.name.to_s
    when :constant_path_node
      [constant_name(node.parent), node.name.to_s].compact.join("::")
    end
  end

  def symbol_name(node)
    node.type == :symbol_node ? node.unescaped : nil
  end

  def unwrap_implicit(node)
    node.type == :implicit_node ? node.value : node
  end

  def render_call?(node)
    node.receiver.nil? && node.name == :render
  end

  def traverse_arguments(node, current_path:, resource_name:, bindings:, loadsites:, skip_keyword_hash: false)
    return unless node.arguments

    node.arguments.arguments.each do |argument|
      next if skip_keyword_hash && argument.type == :keyword_hash_node

      traverse(argument, current_path:, resource_name:, bindings:, loadsites:)
    end
  end

  def traverse_children(node, current_path:, resource_name:, bindings:, loadsites:, skip: [])
    node.compact_child_nodes.each do |child|
      next if skip.include?(child)

      traverse(child, current_path:, resource_name:, bindings:, loadsites:)
    end
  end

  def each_node(node, &block)
    yield node

    node.each_child_node { |child| each_node(child, &block) }
  end
end
