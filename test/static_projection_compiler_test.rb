require_relative "test_helper"

class StaticProjectionCompilerTest < Minitest::Test
  def setup
    @original_connection_defined = Post.instance_variable_defined?(:@connection)
    @original_connection = Post.instance_variable_get(:@connection) if @original_connection_defined
    ProjectionRegistry.load!
  end

  def teardown
    if @original_connection_defined
      Post.instance_variable_set(:@connection, @original_connection)
    elsif Post.instance_variable_defined?(:@connection)
      Post.remove_instance_variable(:@connection)
    end
  end

  def test_compiles_expected_columns_for_current_posts_routes
    controller_path = File.expand_path("../app/controllers/posts_controller.rb", __dir__)

    assert_equal %w[id title created_at], ProjectionRegistry.lookup(
      path: controller_path,
      line: line_number(controller_path, "Post.all"),
      model_class: Post,
      query_kind: :all
    )

    assert_equal %w[title content], ProjectionRegistry.lookup(
      path: controller_path,
      line: line_number(controller_path, "Post.find"),
      model_class: Post,
      query_kind: :find
    )
  end

  def test_index_route_uses_projected_select_list
    fake_connection = FakeConnection.new([{ "id" => 1, "title" => "First post", "created_at" => Time.utc(2024, 1, 1) }])
    Post.instance_variable_set(:@connection, fake_connection)

    status, headers, body = Router.new.call(Rack::MockRequest.env_for("/posts"))

    assert_equal 200, status
    assert_equal "text/html", headers["Content-Type"]
    assert_equal ["SELECT id, title, created_at FROM posts"], fake_connection.queries
    assert_includes body.join, "First post"
  end

  def test_show_route_uses_projected_select_list
    fake_connection = FakeConnection.new([{ "title" => "First post", "content" => "Projected content" }])
    Post.instance_variable_set(:@connection, fake_connection)

    status, headers, body = Router.new.call(Rack::MockRequest.env_for("/posts/1"))

    assert_equal 200, status
    assert_equal "text/html", headers["Content-Type"]
    assert_equal ["SELECT title, content FROM posts WHERE id = 1 LIMIT 1"], fake_connection.queries
    assert_includes body.join, "Projected content"
  end

  def test_missing_projected_attribute_raises_with_callsite_details
    fake_connection = FakeConnection.new([{ "title" => "Only title" }])
    Post.instance_variable_set(:@connection, fake_connection)

    error = assert_raises(MissingProjectedAttributeError) do
      Post.find(1, select: %w[title]).updated_at
    end

    assert_includes error.message, "Post#updated_at"
    assert_includes error.message, File.basename(__FILE__)
    assert_includes error.message, "Loaded columns: title"
  end

  def test_public_send_marks_loadsite_as_unsafe
    with_compiler_fixture(
      controller_source: <<~RUBY,
        class PostsController < Controller
          def index
            posts = Post.all

            render "index", posts:
          end
        end
      RUBY
      view_source: <<~ERB
        <% posts.each do |post| %>
          <%= post.public_send(:title) %>
        <% end %>
      ERB
    ) do |compiler, controller_path|
      projections = compiler.compile

      assert_same ProjectionRegistry::UNSAFE, projections[projection_key(controller_path, "Post.all", :all)]
    end
  end

  def test_local_reassignment_marks_loadsite_as_unsafe
    with_compiler_fixture(
      controller_source: <<~RUBY,
        class PostsController < Controller
          def index
            posts = Post.all
            posts = []

            render "index", posts:
          end
        end
      RUBY
      view_source: <<~ERB
        <% posts.each do |post| %>
          <%= post.title %>
        <% end %>
      ERB
    ) do |compiler, controller_path|
      projections = compiler.compile

      assert_same ProjectionRegistry::UNSAFE, projections[projection_key(controller_path, "Post.all", :all)]
    end
  end

  private

  def line_number(path, needle)
    File.readlines(path).index { |line| line.include?(needle) } + 1
  end

  def projection_key(controller_path, needle, query_kind)
    ProjectionRegistry.key_for(
      path: controller_path,
      line: line_number(controller_path, needle),
      model_class: Post,
      query_kind:
    )
  end

  def with_compiler_fixture(controller_source:, view_source:)
    Dir.mktmpdir do |root|
      controller_path = File.join(root, "app/controllers/posts_controller.rb")
      view_path = File.join(root, "app/views/posts/index.html.erb")

      FileUtils.mkdir_p(File.dirname(controller_path))
      FileUtils.mkdir_p(File.dirname(view_path))
      File.write(controller_path, controller_source)
      File.write(view_path, view_source)

      yield StaticProjectionCompiler.new(root:), controller_path
    end
  end
end
