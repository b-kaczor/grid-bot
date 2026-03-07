# frozen_string_literal: true

# Serve pre-built Vite assets from Rails' public directory during tests.
# The build step runs once before the suite via a before(:suite) hook.

VITE_APP_DIR  = Rails.root.join('frontends/app')
VITE_DIST_DIR = VITE_APP_DIR.join('dist')
VITE_INDEX    = Rails.public_path.join('index.html')
VITE_ASSETS   = Rails.public_path.join('vite-assets')

# Check if the existing dist was built with test env vars.
# A dev build has localhost:3000 as baseURL; test build has /api/v1.
def vite_build_stale?
  return true unless VITE_DIST_DIR.join('index.html').exist?
  return true if ENV['FORCE_VITE_BUILD']

  js_files = Dir.glob(VITE_DIST_DIR.join('vite-assets', '*.js').to_s)
  return true if js_files.empty?

  File.read(js_files.first).include?('localhost:3000')
end

RSpec.configure do |config|
  config.before(:suite) do
    next unless RSpec.configuration.files_to_run.any? { |f| f.include?('spec/features') }

    if vite_build_stale?
      system(
        {
          'VITE_API_URL' => '/api/v1',
          'VITE_CABLE_URL' => '/cable',
          'VITE_TEST_MODE' => '1',
        },
        'npm', 'run', 'build',
        chdir: VITE_APP_DIR.to_s
      ) || raise('Vite build failed')
    end

    # Copy index.html to public/ root so React Router paths work at /
    FileUtils.cp(VITE_DIST_DIR.join('index.html'), VITE_INDEX)

    # Symlink dist/vite-assets -> public/vite-assets
    FileUtils.rm_rf(VITE_ASSETS)
    FileUtils.ln_s(VITE_DIST_DIR.join('vite-assets'), VITE_ASSETS)

    # Wrap the Capybara app with SPA middleware for client-side routing fallback
    Capybara.app = RackSpaMiddleware.new(Rails.application, index_path: VITE_INDEX.to_s)
  end

  config.after(:suite) do
    FileUtils.rm_f(VITE_INDEX)
    FileUtils.rm_rf(VITE_ASSETS)
  end
end
