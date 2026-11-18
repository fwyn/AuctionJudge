# Changelog

## 1.1.0

- The panel separates confirmed upgrades from estimates and shows when the lookup limit has been reached.
- Gear above the character's level shows its required level in the item list.
- `/aj history` shows a short summary of each of the last 20 searches.
- Repeating a search refreshes exact prices and listings for random-stat items.
- The Value column rounds small values to hundredths, so even tiny scores display as `0.00%/s` or `0.00%/g`.

## 1.0.0

First release.

- Panel next to the auction house listing the gear in the current search with price, Sharpie's Gear
  Judge upgrade and value (upgrade per silver or gold).
- Sortable columns; "Upgrades only" and "Hide unusable" filters.
- "Scan specific items": looks up the individual auctions of random-stat items to judge them
  exactly; items not looked up yet are greyed out and marked `*`.
- Click a row to search for that exact item; shift-click to link it.
