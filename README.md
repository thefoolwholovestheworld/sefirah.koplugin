# Sefirah

A web novel and manga library for [KOReader](https://koreader.rocks/). Browse, follow and read your favorite stories, and export them as EPUB or CBZ to read offline. No computer needed.

> **Sefirah is a fork of [Mythos](https://github.com/unitreign/Mythos) by unitreign**, licensed under GPL-3.0. Modified by thefoolwholovestheworld.

## Screenshots

*(Interface shown in French. It follows KOReader's language, or the one you pick in the plugin settings.)*

| ![Library](images/IMG-20261004-WA0011.jpg)<br>Library | ![Browse: sources](images/IMG-20261004-WA0005.jpg)<br>Browse: sources | ![Browse: NovelFire](images/IMG-20261004-WA0003.jpg)<br>Browse: NovelFire |
| --- | --- | --- |
| ![Novel details](images/IMG-20261004-WA0009.jpg)<br>Novel details | ![Chapters](images/IMG-20261004-WA0004.jpg)<br>Chapters | ![Reader reviews](images/IMG-20261004-WA0006.jpg)<br>Reader reviews |
| ![Reader](images/IMG-20261004-WA0008.jpg)<br>Reader | ![Reading settings](images/IMG-20261004-WA0010.jpg)<br>Reading settings | ![Sources](images/IMG-20261004-WA0007.jpg)<br>Sources |

## Features

### Library and browsing

- **Novels | Manga toggle** at the top of the Library, Browse and Sources tabs. If one of the two types is empty, it is grayed out.
- **Library** of the titles you follow, with search and sorting: title (A to Z or Z to A), new chapters first, recently added, recently read. A badge shows the titles that have new chapters.
- **Refresh all** checks every followed novel for new chapters in one go. You can also refresh a single novel by opening it.
- **Browse** the sources you installed, with filters (genre, ranking, period, sorting…) that are remembered for each source, a language filter, and a global search across all sources.
- **Sources are installed on demand.** A source only shows up in Browse once you install it from the Sources tab, where you can also search for an extension by name.
- **Fast loading**: covers are downloaded in parallel and cached on disk. You can turn covers off separately for the Library, Browse and Details pages if your e-reader is slow.

### Novels

- **Novel details**: cover, description, resume reading, favorites.
- **Chapters**: search, jump to a chapter, sort ascending or descending, download a range or everything for offline reading. Downloads run in parallel.
- **New chapter alerts**: each time you go online, a popup tells you about new chapters. You choose whether to be asked for each favorite, to get alerts for all of them, or for none.
- **Reader** built into the plugin: pick your font, text size, line spacing and text width, jump to the previous or next chapter, and use KOReader's own dictionary on any word.
- **Reading statistics**: the time and pages you read in Sefirah are added to KOReader's Statistics, like for any EPUB.
- **Reviews and comments**: reader reviews, plus chapter and paragraph comments. Comments can be downloaded with the chapters to read them offline (slower), or hidden entirely with a long press on the comment icon.
- **Chapter translation**: translate a chapter, from the reader or from the novel page, into the language you choose. Three engines: DeepL Free (API key), Google Translate (free, no key, but slow) or Gemini (free key).
- **EPUB export**: everything in one file, one EPUB per chapter, grouped volumes, or a chapter range. Chapters are fetched in parallel before the EPUB is built.

### Manga

- **Built-in manga reader** (or KOReader's native one, your choice) with reading direction (auto, left to right, right to left), page number display, and automatic jump to the next chapter.
- **Manga and manhwa modes**: very tall pages (webtoons, manhwas) are split into sections that fit the screen width, with smooth scrolling. Grayscale e-readers decode pages in grayscale to save memory.
- **Next chapter preloading** while you read, so it is ready when you reach the last page. You can turn it off.
- **Fast downloads**: up to 20 images at once, several images per connection, and the next chapter starts downloading before the previous one is done.
- **Storage control**: set a maximum space for downloads, delete chapters once read, delete the downloads of a single manga, or clear everything. Page quality can be original or compressed.
- **CBZ export**.

### Interface and settings

- **17 languages**: Arabic, Chinese (simplified and traditional), Dutch, English, French, German, Indonesian, Italian, Japanese, Korean, Polish, Portuguese (Brazil and Portugal), Russian, Spanish and Turkish. It follows KOReader's language, or you can force one in the settings.
- **Settings sorted by category**: General (plugin language, new chapter alerts, offline comments), Covers, Translation (engine, target language, API keys) and Manga (reader, direction, mode, page number, auto next chapter, preloading, quality, cleaning, maximum space).

## Sources

### Novels

| Source | Language |
| --- | --- |
| LightNovelVF | French |
| NovelFrance | French |
| NovelFire | English |
| Royal Road | English |
| Archive of Our Own (AO3) | Multi |
| Wattpad | Multi |
| SkyNovels | Spanish |
| 69书吧 (69shu) | Chinese |

### Manga

| Source | Language |
| --- | --- |
| MangaDex | Multi |
| MangaPill | English |
| FMTeam | French |
| Anime-Sama (scans) | French |

Some sites are protected by Cloudflare or block certain networks, so a source can fail from time to time. Anime-Sama includes a DNS filter bypass for networks that block it. It only works over HTTPS, and not if the block is also applied to the IP address. When a source fails, Sefirah writes a `*_last_error.txt` file in its folder that helps to find out why.

## Installation

1. Download `sefirah.koplugin.zip` from the [latest release](https://github.com/thefoolwholovestheworld/sefirah.koplugin/releases/latest).
2. Extract it so that the `sefirah.koplugin` folder ends up in KOReader's `plugins` directory.
3. Restart KOReader, then open **Sefirah** from the Tools menu.
4. Go to the **Sources** tab and install the sources you want to use.
5. Open **Browse**, pick a novel or a manga, and add it to your library.

To update, close KOReader, replace the whole `sefirah.koplugin` folder with the new one, and restart. Your library and settings are kept.

## Translations

The texts in the code are written in French, and the French text is the key of every translation file in `sefirah.koplugin/locales/`. To fix a translation, edit the matching file and change the value only, never the key. To add a language, copy `en.lua` to `<code>.lua` and translate the values.

Many of the translations are automatic and have not been proofread. If you find a wrong sentence, please open an issue or a pull request.

## Credits and license

Sefirah is based on [Mythos](https://github.com/unitreign/Mythos) by unitreign. Distributed under the **GPL-3.0** license, like the original project. See [NOTICE.md](NOTICE.md).
