Here is the comprehensive **Product Requirements Document (PRD)** for the **Volatility Harvester**.

This document is designed to be handed directly to your Product Owner or Lead Developer. It focuses on **Business Logic, System Behavior, and Feature Sets**, stripping away low-level code implementation details while keeping the functional requirements strict.

---

# Project Name: Volatility Harvester (Grid Trading Bot)

**Version:** 1.0
**Type:** Automated High-Frequency Crypto Trading System
**Stack:** Ruby on Rails (API), React (Dashboard), PostgreSQL, Redis, Sidekiq
**Core Objective:** Generate passive income by automating the "Buy Low, Sell High" loop within a specific price range during sideways market trends.

---

## 1. Executive Summary

The "Volatility Harvester" is a trading automation tool designed to exploit market inefficiencies in the cryptocurrency space. Unlike trend-following bots that hope for a price explosion, this system profits from **market noise**.

**The Thesis:** Crypto assets spend ~70% of their time in "sideways" consolidation. Humans lose money here due to boredom or panic. Our bot will place a "net" (grid) of buy and sell orders to capture profit from every small price fluctuation.

**Key Value Proposition:**

1. **100% Passive:** Once configured, the bot manages the order book 24/7.
2. **Emotionless:** Removes human error (FOMO/Panic Selling).
3. **Cash Flow Generative:** Realizes small profits continuously (USDT accumulation) rather than waiting for a massive capital gain.

---

## 2. System Architecture (High Level)

### A. The Engine (Rails + Sidekiq)

* **Role:** The brain of the operation. It calculates the grid levels, listens to market prices, and executes orders.
* **Concurrency:** Must handle multiple bots running on different pairs (e.g., ETH/USDT and BTC/USDT) simultaneously.
* **State Management:** Uses Redis to store the live state of the Order Book (to avoid hitting DB for every tick).

### B. The Connector (Exchange Layer)

* **Role:** Standardized interface to talk to Exchanges (Binance, Bybit).
* **Requirement:** Must distinguish between **Spot Market** (owning the asset) and **Futures** (optional expansion). *MVP will focus on Spot Market.*

### C. The Dashboard (React)

* **Role:** Visualization and Control.
* **Philosophy:** "Cockpit View." The user needs to see Realized Profit (Cash) vs. Unrealized PnL (Asset Value) instantly.

---

## 3. The Core Logic: "The Grid Algorithm"

This is the most critical section for the development team. The bot must strictly follow this loop.

### 3.1. Initialization (The Setup)

When the user starts a bot, the system takes 4 inputs:

1. **Pair:** (e.g., ETH/USDT)
2. **Lower Price Limit:** (e.g., $2,000)
3. **Upper Price Limit:** (e.g., $3,000)
4. **Grid Quantity:** (e.g., 50 Levels)

**System Action:**

1. Calculates the price difference between levels (Arithmetic or Geometric spacing).
2. Buys the necessary amount of the base asset (ETH) to satisfy the upper sell orders.
3. Places **Limit Buy Orders** below the current price.
4. Places **Limit Sell Orders** above the current price.

### 3.2. The Execution Loop (The Harvest)

The bot monitors the "Filled Orders" stream via WebSocket.

**Scenario A: Price Drops**

1. Market hits a **Buy Order** at $2,500.
2. Order Fills.
3. **Immediate Reaction:** The bot places a **Sell Order** one grid level higher (e.g., at $2,520).
4. *Result:* We have acquired cheap ETH and set a trap to sell it for profit.

**Scenario B: Price Rises**

1. Market hits a **Sell Order** at $2,520.
2. Order Fills.
3. **Immediate Reaction:** The bot places a **Buy Order** one grid level lower (e.g., at $2,500).
4. *Result:* We realized profit in USDT and reset the trap to buy again if it drops.

### 3.3. The Profit Calculation

* **Grid Profit:** The difference between a matched Buy and Sell order (minus fees). This is **Realized Profit**.
* **Floating PnL:** The change in value of the ETH currently held by the bot. This is **Unrealized**.
* *Requirement:* The dashboard must show these two metrics separately.

---

## 4. Key Feature Modules

### Module A: Smart Automation (Trailing Up)

* **Problem:** If the price skyrockets above the Upper Limit ($3,000), the bot sells everything and stops working (we miss the moon).
* **Feature:** **"Trailing Grid"**.
* **Logic:** If the price breaches the top grid, the bot automatically cancels the lowest buy order and moves the entire grid range up by one step (e.g., New Range: $2,020 - $3,020).
* **Benefit:** Keeps the bot running indefinitely during a Bull Run.

### Module B: Risk Management (The Shield)

* **Stop Loss:** A hard trigger price below the Lower Limit. If hit, the bot sells all held crypto to USDT to prevent further loss.
* **Take Profit:** A hard trigger price to close the bot and cash out entirely.

### Module C: Tax & Reporting (The Polish Module)

* **Requirement:** Since this bot generates thousands of transactions, manual accounting is impossible.
* **Feature:** "Export to CSV" compliant with Polish tax standards.
* **Logic:** Must track the Cost Basis of every trade to calculate the exact tax liability.

---

## 5. User Interface (UI) Requirements

### 1. The "Create Bot" Wizard

A simple 3-step form:

* **Step 1:** Select Pair (Dropdown with search).
* **Step 2:** AI Suggestion (Button: "Auto-Fill Parameters").
* *Backend Logic:* Look at the last 30 days of volatility and suggest a safe High/Low range.


* **Step 3:** Investment Amount Slider (e.g., "Use 50% of my USDT").

### 2. The Active Bots Card

Each running bot is displayed as a card showing:

* **Range Visualizer:** A progress bar showing where the current price is relative to Low/High limits.
* **Arbitrage Yield:** "Daily APR" (Current profit extrapolated to a year).
* **Status:** Running / Out of Range / Error.

### 3. The Performance Chart

* Line chart showing **Total Balance** over time.
* Bar chart showing **Daily Realized Profit** (The dopamine hit).

---

## 6. Non-Functional Requirements

### Security

* **API Keys:** Must be encrypted at rest in the database (using `Lockbox` or Rails Credentials).
* **IP Whitelisting:** The bot server's IP must be static so we can whitelist it on Binance/Bybit for added security.
* **Permission Scope:** The API keys should strictly allow "Spot Trading" and **deny** "Withdrawals".

### Reliability

* **Rate Limits:** The system must respect Exchange API limits (e.g., 1200 requests/minute). Implementation of a Redis-backed "Throttle" middleware is required.
* **WebSocket Reconnection:** If the internet flickers, the bot must auto-reconnect to the price stream within 5 seconds.

---

## 7. Implementation Roadmap

### Phase 1: The Skeleton (MVP)

* Connect to Exchange API (Read Balance).
* Implement the mathematical logic for calculating grid lines.
* Place initial dummy orders (Testnet).

### Phase 2: The Loop

* Implement WebSocket listeners for Order Fills.
* Implement the "Buy -> Place Sell" and "Sell -> Place Buy" logic.
* **Milestone:** Complete 100 autonomous trades on Testnet.

### Phase 3: The Dashboard

* Build the React frontend.
* Visualize the live orders on a chart.

### Phase 4: Production & Safety

* Implement Stop Loss & Trailing Up.
* Deploy to Mainnet with real capital (Small cap: $500).

---

## 8. Definition of Success

The project is considered a success when:

1. The user can start a bot on `ETH/USDT` with 3 clicks.
2. The bot runs for 24 hours without crashing or hitting API rate limits.
3. The bot generates profit in a sideways market that exceeds the fee cost.
4. The dashboard accurately reports "Realized Profit" matching the Exchange's actual history.
