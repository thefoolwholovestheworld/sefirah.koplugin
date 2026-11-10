# Sefirah v1.6.1

## Français

### Corrections
- **Bibliothèque** : les mangas lus ou téléchargés apparaissent maintenant dans l'onglet Mangas, sans avoir à les mettre en favori. Ceux déjà commencés sont retrouvés à la première ouverture de la bibliothèque (le titre exact revient quand on ouvre la fiche).
- **Veille** : après une mise en veille de la liseuse, plus besoin de la redémarrer pour rouvrir le plugin.

### Nouveautés
- Option « Manga · Ajout auto à la bibliothèque » dans Paramètres, pour désactiver cet ajout automatique.

## English

### Fixes
- **Library**: manga you've read or downloaded now show up in the Manga tab, no need to add them to favourites. Ones you'd already started are picked up the first time you open the library (the exact title comes back when you open the manga's page).
- **Sleep**: after your e-reader goes to sleep, you no longer have to restart it to reopen the plugin.

### New
- "Manga · Auto-add to library" option in Settings, to turn this off.

---

# Sefirah v1.6

## Français

### Nouveautés
- **10 nouvelles sources au catalogue** : NovelFull, NovelNinja, BeastNovels, Blume-Verse (anglais) ; Azora Manga, Cenele, RewayahFans, SeaNovel (arabe) ; IxDzs8 (chinois) ; Linovelib (chinois traditionnel).
- **Vitesse de lecture (mots/min)** : mesurée pendant la lecture dans le lecteur intégré, à partir des pages vraiment lues (ni liseuse en veille, ni page survolée). Détail dans le centre de progression, désactivable dans Paramètres.
- **Classement** : tes stats (pages lues, chapitres, série, mots/min) sont visibles dans le classement et dans le menu d'un ami.
- **Lecteur de roman** : option pour masquer le titre du chapitre (la flèche retour et l'engrenage restent, le texte gagne la place). Question posée à la première ouverture, modifiable dans Paramètres et dans les réglages de lecture.
- **Liste des chapitres** : s'ouvre sur la page du chapitre en cours de lecture (option dans Paramètres).
- **Sources** : nouveau bouton « Supprimer la source » qui efface le fichier ; une source du Hub se re-télécharge ensuite à tout moment.

### Changements
- **Plus aucune source dans le plugin** : toutes se téléchargent depuis Sefirah Source Hub (onglet Sources › « Actualiser le catalogue », Wi-Fi requis). Le plugin est beaucoup plus léger. Les sources déjà présentes sur ta liseuse continuent de fonctionner. Les icônes du catalogue s'affichent dès l'onglet Sources, et les sources que tu avais installées sont rétablies automatiquement à l'actualisation du catalogue (si un update du plugin les a effacées).
- Traductions : 17 langues complètes, 36 textes inutilisés supprimés.
- Release allégée : captures, dossier `.github`, README de la communauté, `ui/community.lua`, `community_model.lua`, 13 images inutilisées et fichier `.bak` retirés ; icônes des sources déplacées sur le Hub.
- Code mort retiré (MangaBall, quêtes).
- **Correction** : un titre de chapitre long n'est plus coupé à gauche et à droite dans le lecteur de roman.

## English

### New
- **10 new sources in the catalogue**: NovelFull, NovelNinja, BeastNovels, Blume-Verse (English); Azora Manga, Cenele, RewayahFans, SeaNovel (Arabic); IxDzs8 (Chinese); Linovelib (Traditional Chinese).
- **Reading speed (words/min)**: measured while reading in the built-in reader, from pages actually read (not a sleeping device, not a skimmed page). Details in the progress centre, can be turned off in Settings.
- **Leaderboard**: your stats (pages read, chapters, streak, words/min) are shown in the ranking and in a friend's menu.
- **Novel reader**: option to hide the chapter title (the back arrow and the gear stay, the text gets the room). Asked on first opening, changeable in Settings and in the reading settings.
- **Chapter list**: opens on the page of the chapter you are reading (option in Settings).
- **Sources**: new "Delete the source" button that removes the file; a Hub source can be downloaded again at any time.

### Changes
- **No more sources bundled in the plugin**: all of them are downloaded from Sefirah Source Hub (Sources tab › “Refresh the catalogue”, Wi-Fi required). The plugin is much lighter. Sources already on your e-reader keep working. Catalogue icons show up right in the Sources tab, and sources you had installed are restored automatically when the catalogue refreshes (if a plugin update wiped them).
- Translations: 17 languages complete, 36 unused texts removed.
- Lighter release: screenshots, `.github` folder, community README, `ui/community.lua`, `community_model.lua`, 13 unused images and a `.bak` file removed.
- Dead code removed (MangaBall, quests).
- **Fix**: a long chapter title is no longer cut off on the left and right in the novel reader.

---

# Sefirah v1.5

## Français

### Nouveautés
- **Sources** : l'onglet lit le catalogue de Sefirah Source Hub. Un appui sur l'icône d'installation télécharge et installe la source, sans rien copier à la main. L'icône antenne propose « Actualiser le catalogue » ou « Recevoir avec un code ». Un bouton « Mettre à jour » apparaît dans les réglages d'une source du Hub quand une version plus récente existe.
- **Nouvelles extensions** : LNCrawler, MyDramaNovel, WordRain.

### Changements
- **Scribble Hub** retirée.

## English

### New
- **Sources**: the tab reads the Sefirah Source Hub catalogue. Tap the install icon to download and install a source, no manual copying. The antenna icon offers "Refresh the catalogue" or "Receive with a code". An "Update" button shows in the settings of a Hub source when a newer version exists.
- **New extensions**: LNCrawler, MyDramaNovel, WordRain.

### Changes
- **Scribble Hub** removed.

---

# Sefirah v1.4.1

## Français

### Corrections
- **Novelfire** : le site redirige désormais vers novelphoenix.com avec une page JavaScript que KOReader ne peut pas suivre (« Impossible d'extraire le contenu du chapitre »). Sefirah suit maintenant cette redirection, et les chapitres s'ouvrent de nouveau.
- **Novelfire** : les chapitres déjà téléchargés (en erreur) sont supprimés du cache au premier lancement. Les romans de la bibliothèque et la progression sont conservés.
- **Novelfire** : extraction plus robuste si la structure de la page change, et enregistrement de la réponse du site dans `sefirah/novelfire_last_error.txt` en cas d'échec.
- **Ouverture de Sefirah** : correction d'un conflit de nom avec d'autres plugins (« attempt to call method 'get' (a nil value) », `ui/library.lua`).

### Nouveautés
- **TruyenDichAI** : nouvelle extension, avec son icône.

### Changements
- L'onglet **Communauté**, pas terminé, est retiré pour cette version.

## English

### Fixes
- **Novelfire**: the site now redirects to novelphoenix.com through a JavaScript page that KOReader can't follow ("Could not extract chapter content"). Sefirah now follows the redirect, and chapters open again.
- **Novelfire**: already downloaded (broken) chapters are removed from the cache on first launch. Library novels and reading progress are kept.
- **Novelfire**: more robust extraction if the page structure changes, and the site's response is saved to `sefirah/novelfire_last_error.txt` on failure.
- **Opening Sefirah**: fixed a name conflict with other plugins ("attempt to call method 'get' (a nil value)", `ui/library.lua`).

### New
- **TruyenDichAI**: new extension, with its icon.

### Changes
- The unfinished **Community** tab is removed for this release.

---

# Sefirah v1.4

## Français

### Nouveautés
- **Centre de progression** : XP, niveaux, quêtes (quotidiennes, hebdomadaires, du mois) et succès (faciles, moyens, difficiles).
- **Bouton « i »** en haut à droite : explique toutes les façons de gagner de l'XP et le système de niveaux. La fenêtre s'affiche aussi à la première ouverture.
- **XP pour les mangas** : 2 XP par page et 10 XP par chapitre (novels : 5 et 20).
- **Classement communautaire**, **amis** et **photo de profil**.
- **Nouvelle source : MangaBall**.
- **Mode nuit** pour tout le plugin.
- Nouvelles icônes dans les réglages.

### Améliorations
- Ajustements des sources 69shu, Anime-Sama, MangaDex, NovelFrance, Novel Mania, RanobeHub et WEBTOON.
- Améliorations du navigateur, de la bibliothèque, des fiches, du lecteur, de l'export et des téléchargements.
- **Plus fluide et plus rapide** : écritures sur disque regroupées (réglages, bibliothèque, progression de lecture), calcul des quêtes allégé à chaque page tournée, suivi des téléchargements plus réactif.
- Réglages de lecture : on revient à la même page du chapitre (et non plus à la page 1).
- Traductions mises à jour.

### Retiré
- Intégration AniList et ancien écran de statistiques de lecture.

## English

### New
- **Progress center**: XP, levels, quests (daily, weekly, monthly) and achievements (easy, medium, hard).
- **"i" button** (top right): explains every way to earn XP and how levels work. Also shown on first open.
- **XP for manga**: 2 XP per page and 10 XP per chapter (novels: 5 and 20).
- **Community leaderboard**, **friends** and **profile picture**.
- **New source: MangaBall**.
- **Night mode** for the whole plugin.
- New icons in settings.

### Improvements
- Tweaks to the 69shu, Anime-Sama, MangaDex, NovelFrance, Novel Mania, RanobeHub and WEBTOON sources.
- Improvements to browse, library, detail pages, reader, export and downloads.
- **Smoother and faster**: disk writes batched (settings, library, reading progress), lighter quest checks on every page turn, more responsive download tracking.
- Reading settings: you now return to the same page of the chapter (no longer page 1).
- Updated translations.

### Removed
- AniList integration and the old reading statistics screen.
