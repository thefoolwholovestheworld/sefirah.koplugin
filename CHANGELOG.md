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
