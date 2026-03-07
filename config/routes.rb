# frozen_string_literal: true

require 'sidekiq/web'

Sidekiq::Web.use ActionDispatch::Cookies
Sidekiq::Web.use ActionDispatch::Session::CookieStore, key: '_gridbot_sidekiq_session'
unless Rails.env.development?
  Sidekiq::Web.use Rack::Auth::Basic do |username, password|
    ActiveSupport::SecurityUtils.secure_compare(username, ENV.fetch('SIDEKIQ_USERNAME', 'admin')) &
      ActiveSupport::SecurityUtils.secure_compare(password, ENV.fetch('SIDEKIQ_PASSWORD', 'gridbot'))
  end
end

Rails.application.routes.draw do
  mount Sidekiq::Web => '/sidekiq'

  get 'up' => 'rails/health#show', as: :rails_health_check

  namespace :api do
    namespace :v1 do
      resources :bots, only: %i[index show create update destroy] do
        resource :grid, only: [:show], controller: 'bots/grid'
        resources :trades, only: [:index], controller: 'bots/trades'
        resource :chart, only: [:show], controller: 'bots/chart'
      end

      resource :exchange_account, only: [:create] do
        collection do
          get :current, action: :show
          patch :current, action: :update
          post :test
        end
      end

      namespace :exchange do
        resource :pairs, only: [:show]
        resource :balance, only: [:show]
      end
    end
  end

  mount ActionCable.server => '/cable'
end
