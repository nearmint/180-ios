# In-App Messages OneSignal

Mode d'emploi côté dashboard. Le code correspondant vit dans
`180/Services/InAppMessageService.swift`.

## Prérequis technique

Le produit SPM **`OneSignalInAppMessages`** doit rester lié à la cible `180`.
C'est un module distinct de `OneSignalFramework` : le SDK 5 le charge
dynamiquement et, en son absence, retombe sur `OSStubInAppMessages` — tous les
appels IAM deviennent des no-op **silencieux**, et aucun message ne s'affiche.
Le seul indice est une ligne de log du SDK : `OneSignalInAppMessages not found`.

## Faire naviguer un bouton dans l'app

Un bouton d'IAM peut ouvrir une URL (le SDK s'en charge seul, selon le réglage
*Safari* / *Webview* du dashboard) **ou** router vers un écran natif de l'app.
Pour le second cas, renseigner le champ **Action ID** du bouton.

### Forme abrégée

À privilégier — c'est la saisie courante.

| Action ID                     | Effet                                        |
| ----------------------------- | -------------------------------------------- |
| `recipe:123`                  | ouvre la recette 123                          |
| `article:456`                 | ouvre l'article 456 (webview, permalien `?p=`) |
| `url:https://www.180c.fr/…`   | ouvre l'URL en navigateur intégré             |

Le type est insensible à la casse et les espaces de bordure sont tolérés.

### Forme requête

Nécessaire dès qu'il faut porter **à la fois** un id et une URL — donc pour le
type `product`, qui ouvre la page en **webview authentifiée** (session amorcée
avec le JWT de l'utilisateur connecté ; repli sur la page publique sinon) :

```
type=product&id=45&url=https%3A%2F%2Fwww.180c.fr%2Fboutique%2Fabonnement
```

L'URL doit être **percent-encodée** et appartenir au domaine du site
(`180c.fr` / `www.180c.fr`) ; toute autre origine est rejetée.

### Ce qui ne route pas

Un Action ID vide, libre (`fermer`), de type inconnu, ou avec un id ≤ 0 ne
déclenche **aucune** navigation — le message se contente de se fermer. C'est
volontaire : contrairement au tap sur une notification push, qui retombe sur le
centre de notifications, un bouton « Fermer » d'IAM ne doit pas éjecter
l'utilisateur de l'écran où il se trouve.

## Cibler une audience

Deux mécanismes coexistent, et ils ne sont **pas** interchangeables :

- les **tags** (`env`, `subscription_status`, `app_version`) sont évalués côté
  serveur et servent aux segments push ;
- les **triggers** (mêmes clés, plus `logged_in`) sont évalués côté client et
  sont les seuls utilisables comme conditions d'audience d'un IAM.

Les deux sont posés ensemble par `PushNotificationService.applyTags()`, à chaque
changement d'état (connexion, abonnement).

Triggers disponibles en permanence :

| Clé                   | Valeurs                              |
| --------------------- | ------------------------------------ |
| `logged_in`           | `true` / `false`                     |
| `subscription_status` | `active` / `none`                    |
| `env`                 | `debug` / `testflight` / `appstore`  |
| `app_version`         | ex. `1.0.5`                          |

Le tag `env` permet de restreindre un message de test à TestFlight avant de
l'ouvrir à l'App Store.

Des triggers ponctuels peuvent être posés depuis le code via
`InAppMessageService.shared.setTrigger(_:_:)` — utile pour déclencher un message
sur un écran ou un geste précis.

## Suspendre l'affichage

`InAppMessageService.shared.isPaused` suspend les IAM. Non activé par défaut. Le
levier existe pour les moments où une interruption serait néfaste (mise à jour
forcée, onboarding, lecture d'une recette — cette dernière suit déjà cette
politique pour le soft ask notifications, cf. `PushPermissionCoordinator`).

## Mesure

Deux événements Firebase sont émis : `iam_displayed` (`message_id`) et
`iam_clicked` (`message_id`, `action_id`). Ils doublent les statistiques du
dashboard OneSignal, mais permettent de croiser les IAM avec le reste des
parcours dans Analytics.
