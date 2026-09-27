# Fiche App Store Connect — métadonnées

Métadonnées de production de l'app **180°C**, structurées pour
[`fastlane deliver`](https://docs.fastlane.tools/actions/deliver/).
Source : cahier des charges (section 3 « Fiche App Store Connect »).

> L'upload nécessite un compte Apple Developer actif et un enregistrement
> App Store Connect (App Store ID).

## Contenu

| Fichier | Champ App Store Connect | Limite |
|---|---|---|
| `fr-FR/name.txt` | Nom de l'app | 30 car. |
| `fr-FR/subtitle.txt` | Sous-titre | 30 car. |
| `fr-FR/description.txt` | Description | 4 000 car. |
| `fr-FR/keywords.txt` | Mots-clés (séparés par virgules, sans espace) | 100 car. |
| `fr-FR/promotional_text.txt` | Texte promotionnel | 170 car. |
| `fr-FR/marketing_url.txt` | URL marketing | — |
| `fr-FR/support_url.txt` | URL support | — |
| `fr-FR/privacy_url.txt` | URL politique de confidentialité | — |
| `copyright.txt` | Copyright | — |
| `primary_category.txt` | Catégorie primaire (`FOOD_AND_DRINK`) | — |
| `secondary_category.txt` | Catégorie secondaire (`MAGAZINES_AND_NEWSPAPERS`) | — |

Langue principale : **français (fr-FR)**. Classification d'âge : **4+**
(à régler dans App Store Connect, non géré par les fichiers metadata).

## Captures d'écran

`fastlane deliver` attend les screenshots dans `fastlane/screenshots/fr-FR/`.
La production des captures est décrite dans `fastlane/screenshots/fr-FR/README.md`.

## Pousser la fiche (plus tard)

```bash
# Depuis la racine du repo, une fois le compte ASC actif :
fastlane deliver --skip_binary_upload --skip_screenshots
```
