# AuctionJudge

Judges the gear on the auction house for your character, so you can see which auctions are real
upgrades and which of those are the best value.

AuctionJudge adds a panel to the right of the auction house window. For the search you just ran, it
lists every piece of gear with:

- its price,
- how much of an upgrade it is for your character, as judged by
  [Sharpie's Gear Judge](https://www.curseforge.com/wow/addons/sharpies-gear-judge),
- and its value: upgrade per silver (or per gold for items priced in gold).

Click a column header to sort. By default the best value is at the top.

For World of Warcraft Forever.

## Requirements

- **Sharpie's Gear Judge** (required). AuctionJudge uses its public addon interface to score items,
  so the numbers are the same ones you see in its tooltips, for the spec it judges you by.

## Using it

1. Open the auction house and search for gear, for example a weapon or an armour slot.
2. The panel fills in next to the auction house window.
3. Click a row to search for exactly that item. Shift-click to link it in chat.

Options in the panel:

- **Upgrades only** - show positive scores. The panel counts confirmed upgrades separately from
  positive estimates. A group with a negative base estimate can still contain an upgrade,
  so it remains eligible for a lookup even when this filter hides it.
- **Hide unusable** - hide items Sharpie's Gear Judge rules out for your character. Gear you can
  grow into stays in the list. For example, a level 10 character sees **Requires 15** on a row
  for an item that requires level 15. A question mark means the level comes from the base item
  while the requirement for that random-stat group is still unknown.
- **Scan specific items** - items with random stats ("of the Bear", "of Intellect", ...) are sold in
  groups whose stats differ, so they can only be judged exactly by looking at the individual
  auctions. With this option on, AuctionJudge looks those up for you. Until an item has been looked
  up it is shown greyed out with its base score marked `*`. Scan progress shows how many groups
  have been checked and whether the lookup limit stopped the scan. If the auction house has more
  browse results to load, the panel reports that separately.

The panel can be closed with its close button; a small "AJ" button on the auction house window
brings it back.

## What it does and does not do

- It never buys, bids, posts or cancels anything.
- It reads the results of the searches you run yourself.
- With **Scan specific items** on, it also sends item lookups for random-stat items in your
  results: one at a time, paced, cheapest first, at most 60 per search. They stop when you start a
  new search or close the auction house. Turn the option off if you do not want any extra searches.
- It does not scan the whole auction house and keeps no price history.

## Commands

`/aj` or `/auctionjudge`:

- `show`, `hide`, `toggle` - the panel.
- `exact on|off` - same as the "Scan specific items" checkbox.
- `maxqueries <n>` - the most item lookups per search (default 60).
- `status` - what the addon found and what it is doing.
- `history` - summaries of the last 20 searches across the account, including the result count,
  exact lookups, confirmed upgrades and how the scan ended. Only the most recent useful search
  keeps detailed rows for debugging.
- `debug [text]` - details per row, for troubleshooting.

## Notes

- Scores depend on your current gear, level, talents and Sharpie's Gear Judge settings, and update
  when those change.
- An upgrade percentage says how much better your whole character gets, not just that slot.

## License

MIT. See [LICENSE](LICENSE).
