# Kompendium Projektu: Grid Trading Bot (Volatility Harvester)

## 1. Matematyka i Konfiguracja (Siatka)

To są sztywne zasady, których bot musi przestrzegać, aby nie tracić pieniędzy na opłatach.

* **Złota Zasada 1%:**
* Celujemy w **~1% zysku na jeden szczebel** (Grid) po odjęciu opłat.
* Wzór dla Devów: `(Cena_Sprzedaży - Cena_Kupna) / Cena_Kupna ≈ 1.0%`.


* **Pułapka Opłat (The Fee Trap):**
* Giełda zabiera ok. 0.2% (kupno + sprzedaż).
* Absolutne minimum rozstawu siatki to **0.5%**. Poniżej tego poziomu karmisz tylko giełdę.
* **Optymalny rozstaw:**
* **0.5% - 0.8%** dla stabilnych par (BTC/ETH).
* **1.0% - 2.0%** dla Altcoinów (większa zmienność).




* **Rodzaj Siatki:**
* Zawsze używamy siatki **Geometrycznej** (stały %), a nie Arytmetycznej (stała kwota $).


* **Ustalanie Zakresu (Range):**
* Nie zgadujemy. Używamy wskaźnika **Wstęgi Bollingera (4H)** lub **Min/Max z ostatnich 30 dni**.



## 2. Wymogi Techniczne (Dla Zespołu Ruby/React)

Kluczowe funkcjonalności backendu, bez których bot będzie wadliwy.

* **Tryb "Post-Only" (Krytyczne):**
* Wszystkie zlecenia LIMIT muszą mieć flagę `timeInForce: "GTX"` (lub `isPostOnly: true`).
* To gwarantuje, że płacimy niższą prowizję (Maker Fee) i nie wpadamy w droższą prowizję (Taker Fee) przez przypadek.


* **Logika Pętli (Ping-Pong):**
* Na danym poziomie cenowym może istnieć tylko **jedno** aktywne zlecenie.
* Jeśli zlecenie **SELL** na 2100$ wejdzie -> Bot natychmiast stawia **BUY** na 2000$ (szczebel niżej).
* Bot ma "łatać dziury" za ceną, a nie ją gonić.


* **Obsługa Luk (Gaps):**
* Jeśli cena przeskoczy nad zleceniem (np. pompa o 5%), bot wypełnia brakujące zlecenia kupna poniżej aktualnej ceny, tworząc "podłogę".



## 3. Strategia Wyjścia (Take Profit & Stop Loss)

Jak zarządzamy ryzykiem i kiedy kończymy zabawę.

* **Take Profit (TP):**
* Nie ustawiamy sztywnego TP.
* **Górna granica siatki JEST naszym Take Profit.** Po jej przebiciu bot sprzedaje wszystko i zostaje z 100% USDT (Cash).


* **Stop Loss (SL):**
* **Dla BTC/ETH:** Sugerowany **BRAK Stop Loss**. Traktujemy spadki jako inwestycję długoterminową ("Bag Holding"). Czekamy na odbicie.
* **Dla Altcoinów:** Stop Loss **OBOWIĄZKOWY**. Jeśli cena spadnie poniżej siatki, tniemy straty, bo shitcoin może spaść do zera.


* **Trailing Up (Ruchoma Siatka):**
* W wersji MVP **odradzam automatyczne przesuwanie siatki w górę**.
* Ryzyko: "Top-Buyer Trap" – bot przesunie siatkę na sam szczyt bańki, a potem nastąpi krach.
* Rozwiązanie: Po przebiciu sufitu bot wchodzi w stan **IDLE** i wysyła powiadomienie. Decyzję o restarcie podejmujesz ręcznie.



## 4. Timing (Kiedy włączyć bota?)

Bot najlepiej radzi sobie w "nudzie" (konsolidacji).

* **Sygnały START:**
* **Wstęgi Bollingera:** Są płaskie i poziome (cena odbija się góra-dół).
* **RSI (4H):** Wynosi pomiędzy **40 a 60** (brak wyraźnego trendu).
* **ADX:** Poniżej 25 (brak siły trendu).


* **Sygnały STOP (Nie wchodzić):**
* RSI > 70 (Wykupienie/Górka) lub RSI < 30 (Panika/Spadający nóż).
* Gwałtowne rozszerzenie wstęg Bollingera (Wybuch zmienności).


* **Najlepszy moment:** Zaraz po dużej pompie lub dużym spadku, gdy rynek "odpoczywa" i rysuje poziome kreski przez 2-3 dni.

## 5. Podsumowanie dla Inwestora (Ciebie)

1. **Kapitał:** Najlepiej > 500-1000$ (żeby pokryć min. zlecenia giełdy).
2. **Rynek:** Spot (Bezpieczny) > Futures (Ryzykowny).
3. **Para:** ETH/USDT lub BTC/USDT (najbezpieczniejsze do trzymania w razie spadków).
4. **Cel:** Generowanie pasywnego dochodu z "szumu" rynkowego, a nie trafienie w "to the moon".

Czy Twój zespół ma już wszystko, czego potrzebuje, aby ruszyć z kodowaniem MVP?
