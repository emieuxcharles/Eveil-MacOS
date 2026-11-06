# Eveil

Une application macOS pour maintenir votre Mac éveillé depuis la barre des menus, pendant **1, 2 ou 3 heures**, ou sans limite de durée.

**Compatibilité :** Mac Apple Silicon · macOS 14 ou ultérieur.

## Installation

1. Téléchargez l’archive de la version souhaitée depuis [Releases](https://github.com/emieuxcharles/Eveil-MacOS/releases).
2. Décompressez-la, ouvrez **Eveil.app**, puis choisissez **Installer dans Applications** si proposé.
3. Activez le service et autorisez Eveil dans les réglages macOS si demandé. Revenez dans l’app pour vérifier l’autorisation.

## Utilisation

Cliquez sur le soleil dans la barre des menus, choisissez une durée et activez **Maintenir éveillé**.

À la fin du compte à rebours, à la désactivation ou lorsque vous quittez l’application, Eveil rétablit la veille et les réglages d’économie d’énergie précédents. Fermer le panneau laisse la session active.

Pendant une session, le mode économie d’énergie est activé. Si macOS signale un état thermique sérieux ou critique, Eveil arrête la session et demande la mise en veille.

**Gardez le Mac ventilé : ces protections ne rendent pas son utilisation dans un sac fermé sûre.**

Pour désinstaller : dans les réglages d’Eveil, choisissez **Retirer le service…**, attendez la confirmation, quittez l’app puis placez-la dans la Corbeille. En cas de problème, utilisez **Exporter le diagnostic…** dans les réglages.

## Développement

Avec Xcode et ses outils de ligne de commande :

```sh
swift test
swift build -c release
```

Pour créer `dist/Eveil.app`, signée avec votre certificat Developer ID :

```sh
EVEIL2_SIGN_IDENTITY="EMPREINTE_DU_CERTIFICAT" ./scripts/build.sh
```

L’application et son service exigent une signature de l’équipe Apple configurée dans `Sources/EveilIPC/Protocol.swift`.

## Releases automatiques

- **Push sur `main` ou pull request vers `main` :** tests et compilation.
- **Tag `vMAJOR.MINOR.PATCH` :** tests, signature, validation Apple et publication de l’archive avec son empreinte SHA-256. Un contrôle en échec bloque la publication.

Pour publier une nouvelle version, modifiez `CFBundleShortVersionString` et incrémentez `CFBundleVersion` dans `Resources/Info.plist`. Poussez ce changement sur `main`, puis créez le tag correspondant, par exemple pour la version `2.0.1` :

```sh
git tag v2.0.1
git push origin v2.0.1
```

Le tag doit correspondre à la version de l’app et désigner un commit présent sur `main`. Les releases existantes ne sont pas remplacées.

La publication nécessite ces quatre [secrets GitHub Actions](https://github.com/emieuxcharles/Eveil-MacOS/settings/secrets/actions) :

| Secret | Contenu |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Certificat Developer ID avec sa clé privée, exporté en `.p12` et encodé en Base64 |
| `APPLE_CERTIFICATE_PASSWORD` | Mot de passe du fichier `.p12` |
| `APPLE_ID` | Compte Apple Developer utilisé pour la notarisation |
| `APPLE_APP_PASSWORD` | Mot de passe Apple spécifique à l’application |

Ne placez jamais ces valeurs dans le dépôt. Les tests automatisés ne remplacent pas la vérification du service et de la restauration des réglages sur un Mac réel.
