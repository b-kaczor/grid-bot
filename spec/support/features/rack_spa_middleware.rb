# frozen_string_literal: true

# Rack middleware that serves the SPA index.html for any non-API 404 response.
# This enables client-side routing (React Router) when Rails has no matching route.
class RackSpaMiddleware
  def initialize(app, index_path:)
    @app = app
    @index_path = index_path
  end

  def call(env)
    status, headers, body = @app.call(env)

    if status == 404 && !api_request?(env['PATH_INFO'])
      [200, { 'Content-Type' => 'text/html' }, [File.read(@index_path)]]
    else
      [status, headers, body]
    end
  end

  private

  def api_request?(path)
    path.start_with?('/api/', '/cable', '/vite-assets/')
  end
end
