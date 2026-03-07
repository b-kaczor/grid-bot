# frozen_string_literal: true

Rails.application.routes.draw do
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
