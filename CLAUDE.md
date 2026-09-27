# 180°C - App iOS

## Projet
App iOS native pour le site de cuisine 180c.fr (WordPress + WooCommerce).
Consultation de recettes pour abonnés.

## Stack
- SwiftUI (iOS 17+)
- WordPress REST API multi-environnement (prod `180c.fr` ↔ local `180c.local`)
- Pas de dépendances externes (hors Firebase Analytics)

## Environnements (multi-env)
- `API_BASE_URL` / `WEB_BASE_URL` injectés dans l'Info.plist via xcconfig selon la config :
  - `Config/Local.xcconfig` (Debug) → `180c.local`, `IS_LOCAL=YES`, ATS scopée à `180c.local`.
  - `Config/Release.xcconfig` (Release) → `www.180c.fr` (canonique), sans ATS.
- `APIConfig` (`180/APIConfig.swift`) est la **source unique** des URLs (REST + liens web). Aucune URL en dur ailleurs. Chaque environnement pointe sur son domaine **canonique** : prod = `www.180c.fr` (l'apex `180c.fr` fait un 301 qui dégrade les POST) ; local = `180c.local` (l'apex, `www.180c.local` n'existant pas).
- Schemes : `180-Local` (Debug → local) · `180` (Release → prod).
- Bundle id : `fr.thermostat6.app180`.

## Versionnage iOS
- `CURRENT_PROJECT_VERSION` et `MARKETING_VERSION` sont définis au niveau **PROJET**. Les cibles app et extension en **héritent** ; `180Tests` conserve sa surcharge locale.
- **Pour bumper** : sélectionner le PROJET dans le navigateur Xcode → onglet **Build Settings**. Ne **jamais** passer par l'onglet **General** d'une cible — il écrit au niveau cible et recrée la divergence app/extension qui fait **rejeter l'archive** par App Store Connect.
- `IPHONEOS_DEPLOYMENT_TARGET` est défini au niveau **PROJET**, à **17.0** ; les trois cibles en héritent. Minimum établi empiriquement : **16.4 casse** sur `ContentUnavailableView` et `onChange(of:initial:_:)`. La valeur d'origine (26.2) était un **effet de bord** de la création du projet dans Xcode, pas une décision.

## Outillage
- Les micro-éditions de `project.pbxproj` (build settings, versions) se font **à la main**. La gem `xcodeproj` re-sérialise le fichier et introduit des effets de bord ; la réserver aux changements **structurels** (nouveau target, ajout SPM).

## Structure
- Models.swift : modèles (Recipe ACF, IngredientGroup, RecipeStep, Term, Media)
- APIConfig.swift : URLs multi-env (REST + web)
- RecipeTaxonomyResolver.swift : résolution slug → term ID des taxonomies recipe_*
- APIService.swift : appels REST API WordPress (CPT `recipe`)
- ContentView.swift : TabView (4 onglets)
- HomeView.swift : écran d'accueil éditorialisé
- RecipeCards.swift : composants visuels (FeaturedRecipeCard, RecipeCard, RecipeRowCard)
- RecipeListView.swift : liste filtrée par taxonomie (slugs)
- RecipeDetailView.swift : détail d'une recette
- SearchView.swift : recherche + exploration
- FavoritesView.swift : favoris (UserDefaults)
- AccountView.swift : compte (placeholder)

## Modèle recette (CPT `recipe`)
Les recettes sont servies par `wp/v2/recipe?_embed` (CPT `recipe`), plus de `wp/v2/posts`.
Contenu lu depuis les champs ACF structurés (`recipe_intro`, `servings`, `ingredients_groups`,
`steps`, `recipe_is_premium`, `source_issue`) — **plus aucun parsing HTML**.

### Taxonomies (termes résolus par **slug** au runtime, aucun ID en dur)
- `recipe_category` (hiérarchique) — types de plat : `entree`, `plat`, `dessert`, `apero`, `accompagnement`
- `recipe_season` — saisons : `printemps`, `ete`, `automne`, `hiver`
- `recipe_type` — publications : `cahiers-de-delphine`, `revue-180c`, `hors-serie`

> Slugs attendus dans `180/Constants.swift`. `RecipeTaxonomyResolver` mappe slug → ID en
> interrogeant la taxonomie ; un slug introuvable = filtre vide (dégradation propre).

## Conventions
- Langue de l'UI : français
- Couleur d'accent : orange
- Pas de paywall ni restriction dans l'app pour l'instant
- Toujours utiliser async/await pour les appels réseau
