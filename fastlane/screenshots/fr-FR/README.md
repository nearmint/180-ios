# Screenshots App Store — fr-FR (INIT-47)

Déposer ici les captures finales (`.png`) attendues par `fastlane deliver`.
Les `.png` sont ignorés par git (`.gitignore`) ; seul ce README est versionné.

## Tailles requises (App Store Connect)

| Affichage | Appareil de référence | Résolution portrait | Statut |
|---|---|---|---|
| 6,7" | iPhone 15 Pro Max | 1290 × 2796 | **obligatoire** |
| 6,5" | iPhone 11 Pro Max | 1242 × 2688 | **obligatoire** |
| 5,5" | iPhone 8 Plus | 1242 × 2208 | optionnel |

**5 à 10 captures par taille.**

## Écrans à présenter (cf. spec INIT-47 §4)

1. Home éditorialisé
2. Détail recette (+ paywall / abonnement)
3. Recherche & filtres
4. Favoris
5. Compte / abonnement

## Workflow

1. Lancer l'app sur le simulateur Xcode correspondant.
2. Capturer (`Cmd+S` dans le simulateur).
3. Habiller dans Figma : mockup d'appareil + texte marketing.
4. Exporter en PNG aux résolutions ci-dessus et déposer dans ce dossier.
