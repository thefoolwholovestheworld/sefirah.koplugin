# Sefirah

**Your web novels, fanfiction, manga and webtoons, directly in [KOReader](https://koreader.rocks/).**

Browse multiple sources, follow your favorite stories, download chapters and read offline. Export novels as **EPUB** and manga as **CBZ**, without a computer to prepare your reading.

> **Sefirah is a fork of [Mythos](https://github.com/unitreign/Mythos), created by unitreign**, distributed under the **GPL-3.0** license and modified by **thefoolwholovestheworld**.

## Screenshots

*The interface follows KOReader's language unless you select another language in the plugin settings. The screenshots below show the French interface. Appearance may vary between versions.*

| Library | Browse sources | NovelFire catalog |
| :---: | :---: | :---: |
| ![Library](images/IMG-20261004-WA0011.jpg) | ![Browse sources](images/IMG-20261004-WA0005.jpg) | ![NovelFire catalog](images/IMG-20261004-WA0003.jpg) |

| Novel details | Chapters | Reader reviews |
| :---: | :---: | :---: |
| ![Novel details](images/IMG-20261004-WA0009.jpg) | ![Chapters](images/IMG-20261004-WA0004.jpg) | ![Reader reviews](images/IMG-20261004-WA0006.jpg) |

| Built-in reader | Reading settings | Source management |
| :---: | :---: | :---: |
| ![Built-in reader](images/IMG-20261004-WA0008.jpg) | ![Reading settings](images/IMG-20261004-WA0010.jpg) | ![Source management](images/IMG-20261004-WA0007.jpg) |

## Features

### Library and discovery

- **Novels and manga:** switch between content types in the Library, Browse and Sources tabs.
- **Personal library:** keep track of followed titles and resume reading.
- **Search and sorting:** alphabetical order, new chapters, recently added or recently read.
- **Release tracking:** refresh one title or your entire library to check for new chapters.
- **Global search** across installed sources.
- **Browsing filters**, depending on the source: genres, rankings, time periods and sorting.
- **Filters remembered per source**, with source filtering by language.
- **Sources installed on demand** from the Sources tab.
- **Cached covers**, with separate options to disable them in the library, catalogs and title details.

### Novels and fanfiction

- **Title details** with cover, description, favorites and resume reading.
- **Chapter management:** search, jump to a chapter, and sort in ascending or descending order.
- **Built-in reader** with font selection, text size, line spacing and text width settings.
- **KOReader dictionary integration** while reading.
- **Previous and next chapter navigation**.
- **New chapter alerts** when connecting to the network, according to your preferences.
- **Reviews and comments**, where supported by the source: title reviews, chapter comments and paragraph comments.
- **Optional offline comments.** Downloading comments can make chapter downloads slower.
- **Hide comments and reviews** by long-pressing the corresponding icon.

*Available features depend on the source.*

### Downloads and offline reading

- **Download chapters** to prepare your reading without an internet connection.
- **Persistent download queue**, retained after restarting KOReader.
- **Pause, resume and cancel** downloads.
- **Configurable automatic resume** after a network interruption or restart.
- **Download ahead while reading:** disabled, or 1, 3, 5 or 10 chapters ahead.
- **Configurable progress notifications**.
- The queue waits for the network to return **without turning Wi-Fi back on itself**.

### Chapter translation

Translate a chapter from the reader or the title details page into your chosen language.

| Engine | Setup |
| --- | --- |
| **DeepL** | API key required |
| **Google Translate** | No API key required |
| **Gemini** | API key required |

*Availability, quotas and any charges depend on the provider. Text submitted for translation is sent to the selected service.*

### EPUB export

Export novels in the format that suits your reading:

- **One EPUB containing the selected chapters**.
- **One EPUB per chapter**.
- **Grouped volumes**.
- **A chapter range**.

Chapters are fetched before the EPUB is built.

### Manga, manhwa and webtoons

- Choose between **Sefirah's built-in reader** and **KOReader's native reader**.
- **Configurable reading direction:** automatic, left to right or right to left.
- **Manga and manhwa modes** for traditional pages and long vertical images.
- **Long pages split into screen-sized sections**.
- **Optional rotation of double-page spreads**.
- **Page number display** and automatic navigation to the next chapter.
- **Next chapter preloading**, which can be disabled.
- **Parallel image downloads**.
- **Configurable image quality:** original or compressed.
- **Storage management:** space limit, delete after reading, cleanup by title or remove all downloads.
- **CBZ export** for offline reading.

### Progress center

Track your reading activity in a dedicated space:

- **XP and levels**.
- **Daily, weekly and monthly quests**.
- **Achievements** organized by difficulty.
- **Pages, chapters and reading time tracking**.
- **Reading streaks**.
- **Optional community leaderboard**.
- **Friends and profile picture**.
- **Help screen** explaining levels and ways to earn XP.

Local progress and quests are managed on the device. Community features require an internet connection and the configured leaderboard service.

### Interface and customization

- **Night mode** throughout the plugin.
- **17 interface languages:** Arabic, Chinese (Simplified and Traditional), Dutch, English, French, German, Indonesian, Italian, Japanese, Korean, Polish, Portuguese (Brazil and Portugal), Russian, Spanish and Turkish.
- **Automatic language selection** based on KOReader, or manual selection.
- **Settings organized by category**, including downloads, covers, translation and manga.
- **Reset progression statistics** without deleting your library or downloads.

## Sources

Install sources from the **Sources** tab. Once installed, they appear in **Browse**.

### Novels and fanfiction

| Source |
| --- |
| 69书吧 — 69shu |
| Archive of Our Own — AO3 |
| Kakuyomu |
| LightNovelVF |
| Novel Mania |
| NovelFire |
| NovelFrance |
| RanobeHub |
| Royal Road |
| SkyNovels |
| Wattpad |

### Manga and webtoons

| Source |
| --- |
| Anime-Sama |
| FMTeam |
| InManga |
| MangaBall |
| MangaDex |
| MangaPill |
| WEBTOON |

*Source availability depends on the plugin version. Some sources may not be included in older releases.*

### Source availability and limitations

Websites may change their structure, limit requests or use protections that are incompatible with the plugin. **A source being listed does not guarantee uninterrupted access or access to its entire catalog.**

Languages, filters, reviews and comments vary by source. Sefirah does not guarantee access to content requiring authentication, a subscription or an official app.

Use sources and download features in accordance with authors' rights and platform terms.

## Installation

1. Download the plugin archive from the [latest release](https://github.com/thefoolwholovestheworld/sefirah.koplugin/releases/latest).
2. Close KOReader.
3. Extract the archive into KOReader's `plugins` directory.
4. Make sure `main.lua` is directly inside `plugins/sefirah.koplugin/`, with no extra nested folder.
5. Restart KOReader.
6. Open **Sefirah** from the **Tools** menu.
7. Install your preferred sources in **Sources**.
8. Open **Browse**, select a title and add it to your library.

## Updating

1. Close KOReader.
2. Back up your Sefirah data as a precaution.
3. Replace the `sefirah.koplugin` folder with the one from the new release.
4. Restart KOReader.

Settings and library data are stored in KOReader's settings directory, separately from the plugin code. **Do not delete this data when updating.**

## Troubleshooting

### Sefirah does not open

- Make sure KOReader was closed while copying the files.
- Check that the archive was fully extracted.
- Make sure the plugin folder does not contain another nested `sefirah.koplugin` folder.
- Copy the complete plugin folder again if an error mentions missing files.

If the plugin fails to open, diagnostic information may be written to **`sefirah/last_open_error.txt`** inside KOReader's settings directory, as well as **`crash.log`**.

### A source stops working

- Check your connection.
- Try again later: the website may be temporarily unavailable.
- Make sure you are using a recent version of Sefirah.
- Check any **`*_last_error.txt`** files generated for the source.

When reporting an issue, include:

- Your KOReader and Sefirah versions.
- Your e-reader model.
- The affected source.
- Steps to reproduce the problem.
- The error message or relevant log, **with API keys and other private information removed**.

Report bugs and source issues through [GitHub Issues](https://github.com/thefoolwholovestheworld/sefirah.koplugin/issues).

## Translations and contributions

The reference strings in the code are written in **French**. Translation files are located in **`locales/`**.

### Fixing a translation

1. Open the file for the relevant language.
2. Edit only the **translated values**.
3. Do not change the **French keys**.
4. Submit your changes in a pull request.

### Adding a language

1. Copy `locales/en.lua`.
2. Rename the copy using the appropriate language code.
3. Translate the values while keeping the keys unchanged.
4. Add the language to the selector in `ui/settings_dialog.lua`.

Some translations are machine-generated and may need proofreading.

Contributions are also welcome for bug fixes, source maintenance and documentation improvements.

## Credits and license

**Original project:** [Mythos](https://github.com/unitreign/Mythos), by **unitreign**.  
**Fork and modifications:** **thefoolwholovestheworld**.

Sefirah is distributed under the **GPL-3.0** license, like the original project.

See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) for licensing and attribution details.
