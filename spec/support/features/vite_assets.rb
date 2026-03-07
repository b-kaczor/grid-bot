# frozen_string_literal: true

# Serve pre-built Vite assets from Rails' public directory during tests.
# The build step runs once before the suite via a before(:suite) hook.

VITE_APP_DIR  = Rails.root.join('frontends/app')
VITE_DIST_DIR = VITE_APP_DIR.join('dist')
VITE_INDEX    = Rails.public_path.join('index.html')
VITE_ASSETS   = Rails.public_path.join('vite-assets')

RSpec.configure do |config|
  config.before(:suite) do
    next unless RSpec.configuration.files_to_run.any? { |f| f.include?('spec/features') }

    # Build Vite assets with test-appropriate env vars (skip if dist/ is fresh)
    unless VITE_DIST_DIR.join('index.html').exist? && !ENV['FORCE_VITE_BUILD']
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

    # Symlink dist/assets -> public/vite-assets (avoids collision with Rails asset pipeline)
    FileUtils.rm_rf(VITE_ASSETS)
    FileUtils.ln_s(VITE_DIST_DIR.join('vite-assets'), VITE_ASSETS)

    # Wrap the Capybara app with SPA middleware for client-side routing fallback.
    # Cannot use Rails.application.config.middleware because the stack is frozen after boot.
    Capybara.app = RackSpaMiddleware.new(Rails.application, index_path: VITE_INDEX.to_s)
  end

  config.after(:suite) do
    FileUtils.rm_f(VITE_INDEX)
    FileUtils.rm_rf(VITE_ASSETS)
  end
end
