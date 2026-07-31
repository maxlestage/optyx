import Photos
import PhotosUI
import SwiftUI
import UIKit

// Studio photo : importer une image, lui appliquer la signature d'un objectif,
// l'enregistrer.
//
// Le périmètre est volontairement minuscule (photothèque → rendu → export). La
// version précédente de l'app y avait ajouté caméra temps réel, vidéo,
// profondeur et RAW, et s'y est noyée sans jamais régler le seul reproche qui
// comptait : « les effets ne se voient pas ».
//
// CE FICHIER NE CALCULE RIEN. Tout le rendu vit dans `MoteurOptique`
// (Studio/MoteurOptique.swift), appelé aussi par le viseur caméra. Il n'y a
// aucune bonne raison de dupliquer un moteur : ce dépôt a déjà porté deux
// chemins de rendu, ils ont divergé, et l'utilisateur a passé une douzaine
// d'itérations à répéter « ce n'est pas ce que je vois ».
// Ce qui reste ici relève strictement de l'interface : import, aperçu
// anti-rebondi, comparaison par appui long, export et photothèque.

// MARK: - Vue principale

struct StudioView: View {

    // MARK: État

    @State private var objectif: Lens = Lens.catalog[0]

    /// Curseur d'intensité, dans [0, 1]. En `Double` parce que c'est le type
    /// naturel d'un binding SwiftUI ; converti en `Float` au seul moment du
    /// rendu, où `BokehParams` est en `Float`.
    @State private var intensite: Double = 0.8

    /// Les octets du fichier d'origine, jamais une `UIImage`.
    ///
    /// `Data` est `Sendable` : le passer à une tâche détachée ne pose aucune
    /// question de concurrence, là où une `UIImage` ou un `CGImage` en pose.
    /// Le coût — redécoder le JPEG à chaque rendu — est payé sur un fil de
    /// fond et reste très inférieur au filtrage lui-même.
    @State private var donneesSource: Data?

    /// Version réduite de l'original, pour la comparaison par appui long.
    @State private var apercuOriginal: UIImage?
    @State private var apercuRendu: UIImage?

    @State private var selection: PhotosPickerItem?
    @State private var importEnCours = false
    @State private var calculEnCours = false

    /// Vrai tant que le doigt reste posé sur l'image : on montre alors
    /// l'original. La comparaison est le seul moyen honnête de juger un effet.
    @State private var montreOriginal = false

    /// Rendu d'aperçu en cours. Conservé pour pouvoir l'ANNULER : sans cela,
    /// un balayage du curseur empilerait une dizaine de rendus pleine taille
    /// qui se termineraient tous, dans le désordre, bien après le geste.
    @State private var travailApercu: Task<UIImage?, Never>?

    @State private var enregistrementEnCours = false
    @State private var etatEnregistrement: EtatEnregistrement = .repos

    private enum EtatEnregistrement: Equatable {
        case repos
        case reussi
        case refuse
        case echec
    }

    // MARK: Corps

    var body: some View {
        ZStack {
            // Noir pur sous tout le reste, y compris sous l'encoche et le
            // rebond de défilement : c'est ce que fait le site, et le dégradé
            // ne s'applique qu'au contenu.
            Theme.Couleur.fond.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    entete
                    zoneImage
                    barreOutils
                    rangeeDePuces
                    legendeObjectif
                    curseur
                    boutonEnregistrer
                    noteEtatEnregistrement
                }
                .frame(maxWidth: Theme.Espace.largeurMax)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.Fond.page)
        }
        // La cascade `--accent` du site : posée une fois ici, lue par le
        // curseur, la légende et les puces. La faire descendre en paramètre
        // garantirait qu'une vue l'oublie et retombe sur l'orange.
        .environment(\.accentObjectif, Color(hex: objectif.accent))
        .onChange(of: selection) { _, nouvel in
            chargerPhoto(nouvel)
        }
        .onChange(of: objectif) { _, _ in
            // Changement d'objectif : rendu immédiat. C'est un choix délibéré
            // de l'utilisateur, pas un geste continu — le faire attendre
            // donnerait l'impression que la puce n'a pas répondu.
            relancerApercu(delaiNanosecondes: 0)
        }
        .onChange(of: intensite) { _, _ in
            // Le curseur, lui, émet des dizaines de valeurs par seconde :
            // l'anti-rebond est ce qui empêche l'interface de se figer.
            relancerApercu(delaiNanosecondes: 120_000_000)
        }
    }

    // MARK: En-tête

    private var entete: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STUDIO")
                .font(Theme.Police.marque)
                .tracking(Theme.Tracking.marque)
                .foregroundColor(Theme.Couleur.orange)

            VStack(alignment: .leading, spacing: Theme.Interligne.titreHero) {
                Text("Votre photo,")
                    .foregroundColor(Theme.Couleur.texte)
                Text("leur signature.")
                    .foregroundColor(Theme.Couleur.orange)
            }
            .font(Theme.Police.titreLegende)
            .tracking(Theme.Tracking.titreLegende)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Espace.margeSection)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Zone d'image

    private var zoneImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Rayon.scene, style: .continuous)
                .fill(Theme.Fond.cadreScene)

            if let image = imageAffichee {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                etatVide
            }

            if calculEnCours || importEnCours {
                // Indicateur discret en surimpression plutôt qu'un
                // remplacement de l'image : voir l'aperçu précédent pendant
                // le calcul du suivant donne une continuité que le vide noir
                // détruirait à chaque cran du curseur.
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.Couleur.texte)
                    .padding(14)
                    .background(Color.black.opacity(0.45), in: Circle())
            }

            if montreOriginal && apercuOriginal != nil {
                Text("ORIGINAL")
                    .font(Theme.Police.meta)
                    .tracking(Theme.Tracking.meta)
                    .foregroundColor(Theme.Couleur.texte)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomLeading)
                    .padding(Theme.Espace.margeTitreSurScene)
            }
        }
        // Proportion FIXE, celle des scènes du catalogue. Suivre la proportion
        // de la photo ferait sauter toute la page à l'import, et de nouveau à
        // chaque changement de photo.
        .aspectRatio(Theme.Espace.proportionSceneCarte, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Rayon.scene, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Rayon.scene, style: .continuous)
                .strokeBorder(Theme.Couleur.bordure, lineWidth: Theme.Espace.epaisseurBordure)
        )
        .padding(.horizontal, Theme.Espace.margeSection)
        // Appui maintenu = original. `onPressingChanged` bascule dès que le
        // doigt touche, ce qui est précisément ce qu'on veut d'un comparateur :
        // attendre une demi-seconde avant de montrer l'original rendrait
        // l'aller-retour visuel impossible à suivre. Le `perform` vide est
        // obligatoire mais ne sert à rien : tout se joue au pressé/relâché.
        .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 24) {
            // Volontairement vide.
        } onPressingChanged: { presse in
            guard apercuRendu != nil, apercuOriginal != nil else { return }
            montreOriginal = presse
        }
        .accessibilityLabel(apercuRendu == nil
                            ? "Aucune photo chargée"
                            : "Aperçu du rendu, appui long pour voir l'original")
    }

    /// Image effectivement affichée : le rendu, ou l'original tant que le
    /// doigt est posé. Repli sur l'original tant qu'aucun rendu n'existe, pour
    /// que la photo apparaisse dès l'import sans attendre le premier calcul.
    private var imageAffichee: UIImage? {
        if montreOriginal { return apercuOriginal }
        return apercuRendu ?? apercuOriginal
    }

    private var etatVide: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .regular))
                .foregroundColor(Theme.Couleur.orange)

            Text("Importez une photo")
                .font(Theme.Police.signatureCarte)
                .foregroundColor(Theme.Couleur.texte)

            // La phrase précédente annonçait que les objectifs « se voient
            // surtout sur les scènes qui portent des points lumineux ». C'était
            // devenu une excuse infondée : depuis que la défocalisation de
            // l'arrière-plan et la dérive de couleur sont TOUJOURS actives, tout
            // objectif se voit sur toute photo. Les disques de bokeh, eux,
            // restent conditionnés aux scènes qui portent de vraies sources
            // ponctuelles — et c'est un bonus, pas la condition de l'effet.
            Text("Chaque objectif sépare le sujet du fond, teinte les couleurs et assombrit les coins — sur n'importe quelle photo. Les scènes à points lumineux (guirlandes, ville de nuit, contre-jour) y ajoutent en plus ses disques de bokeh.")
                .font(Theme.Police.recit)
                .lineSpacing(Theme.Interligne.recit)
                .foregroundColor(Theme.Couleur.texteAttenue)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26)
    }

    // MARK: Import

    private var barreOutils: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle")
                    Text(donneesSource == nil ? "Choisir une photo" : "Changer de photo")
                }
                .font(Theme.Police.puce)
                .foregroundColor(Theme.Couleur.textePuce)
                .padding(Theme.Espace.paddingPuce)
                .background(Theme.Couleur.puce, in: Capsule())
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Espace.margeSection)
        .padding(.top, 14)
    }

    // MARK: Choix de l'objectif

    private var rangeeDePuces: some View {
        ScrollViewReader { defilement in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Espace.ecartPuces) {
                    ForEach(Lens.catalog) { candidat in
                        Button {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                objectif = candidat
                            }
                        } label: {
                            PuceStudio(lens: candidat, active: candidat.id == objectif.id)
                        }
                        .buttonStyle(.plain)
                        .id(candidat.id)
                    }
                }
                // Padding DANS la pile et non sur le `ScrollView` : posé à
                // l'extérieur il rognerait la zone de défilement, et la
                // première puce viendrait se coller au bord au premier geste.
                .padding(Theme.Espace.paddingRangeePuces)
            }
            .onChange(of: objectif) { _, nouvel in
                // La neuvième puce est hors écran sur un iPhone : sans
                // recentrage, une sélection faite au clavier ou par VoiceOver
                // laisserait la barre sur une puce inactive.
                withAnimation(.easeInOut(duration: 0.28)) {
                    defilement.scrollTo(nouvel.id, anchor: .center)
                }
            }
        }
        .accessibilityLabel("Choisir un objectif")
    }

    private var legendeObjectif: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(objectif.name)
                    .font(Theme.Police.titreLegende)
                    .tracking(Theme.Tracking.titreLegende)
                    .foregroundColor(Theme.Couleur.texte)

                Text(objectif.focal)
                    .font(Theme.Police.focale)
                    .foregroundColor(Color(hex: objectif.accent))
            }

            Text(objectif.signature)
                .font(Theme.Police.signatureLegende)
                .foregroundColor(Color(hex: objectif.accent))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Espace.margeSection)
        .padding(.top, 2)
    }

    // MARK: Intensité

    private var curseur: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INTENSITÉ")
                .font(Theme.Police.meta)
                .tracking(Theme.Tracking.meta)
                .foregroundColor(Theme.Couleur.texteAttenue)

            CurseurIntensite(valeur: $intensite)
        }
        .padding(.horizontal, Theme.Espace.margeSection)
        .padding(.top, 16)
    }

    // MARK: Enregistrement

    private var boutonEnregistrer: some View {
        Button {
            enregistrer()
        } label: {
            HStack(spacing: 10) {
                if enregistrementEnCours {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Theme.Couleur.texteSurAccent)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
                Text("Enregistrer dans la photothèque")
            }
            .font(Theme.Police.cta)
            .foregroundColor(Theme.Couleur.texteSurAccent)
            .padding(Theme.Espace.paddingCTA)
            .frame(maxWidth: .infinity)
            .background(Theme.Couleur.orange, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(donneesSource == nil || enregistrementEnCours)
        // Le bouton reste EN PLACE quand il est inactif, simplement estompé :
        // le faire disparaître ferait remonter tout le bas de la page à
        // l'import de la première photo.
        .opacity(donneesSource == nil || enregistrementEnCours ? 0.45 : 1)
        .padding(.horizontal, Theme.Espace.margeSection)
        .padding(.top, Theme.Espace.margeHautCTA)
    }

    @ViewBuilder
    private var noteEtatEnregistrement: some View {
        // La confirmation est VISUELLE et persistante jusqu'au geste suivant :
        // une alerte à faire disparaître ajouterait une manipulation à ce qui
        // doit rester un enchaînement d'une seconde.
        HStack(spacing: 8) {
            switch etatEnregistrement {
            case .repos:
                Text("Export en 3200 px sur le plus grand côté, JPEG qualité 92 %.")
                    .foregroundColor(Theme.Couleur.texteDiscret)
            case .reussi:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Theme.Couleur.orange)
                Text("Enregistré dans la photothèque.")
                    .foregroundColor(Theme.Couleur.texteSecondaire)
            case .refuse:
                Image(systemName: "exclamationmark.circle")
                    .foregroundColor(Theme.Couleur.orange)
                Text("Accès à la photothèque refusé. Autorisez l'ajout dans Réglages pour enregistrer.")
                    .foregroundColor(Theme.Couleur.texteSecondaire)
            case .echec:
                Image(systemName: "exclamationmark.circle")
                    .foregroundColor(Theme.Couleur.orange)
                Text("L'enregistrement a échoué. Réessayez.")
                    .foregroundColor(Theme.Couleur.texteSecondaire)
            }
            Spacer(minLength: 0)
        }
        .font(Theme.Police.copyright)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Theme.Espace.margeSection)
        .padding(.top, 10)
        .padding(.bottom, 34)
    }

    // MARK: - Chargement

    private func chargerPhoto(_ element: PhotosPickerItem?) {
        guard let element else { return }
        importEnCours = true
        etatEnregistrement = .repos

        Task { @MainActor in
            // `loadTransferable` livre les octets du fichier : on garde la
            // source intacte pour pouvoir refaire un rendu pleine taille à
            // l'export sans repasser par le sélecteur.
            let donnees = try? await element.loadTransferable(type: Data.self)
            guard let donnees else {
                importEnCours = false
                return
            }

            let reduite = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                MoteurOptique.imageReduite(donnees: donnees, coteMax: MoteurOptique.coteApercu)
            }.value

            donneesSource = donnees
            apercuOriginal = reduite
            apercuRendu = nil
            importEnCours = false
            relancerApercu(delaiNanosecondes: 0)
        }
    }

    // MARK: - Aperçu

    /// Relance le rendu d'aperçu, en annulant le précédent.
    ///
    /// L'anti-rebond vit DANS la tâche détachée : la sommeiller là plutôt que
    /// sur le fil principal permet de n'avoir qu'un seul objet à annuler, et
    /// l'annulation coupe aussi bien pendant l'attente que pendant le calcul.
    private func relancerApercu(delaiNanosecondes: UInt64) {
        travailApercu?.cancel()

        guard let donnees = donneesSource else {
            apercuRendu = nil
            calculEnCours = false
            return
        }

        let choisi = objectif
        let force = Float(intensite)
        calculEnCours = true

        let travail = Task.detached(priority: .userInitiated) { () -> UIImage? in
            if delaiNanosecondes > 0 {
                try? await Task.sleep(nanoseconds: delaiNanosecondes)
            }
            if Task.isCancelled { return nil }
            return MoteurOptique.rendre(donnees: donnees,
                                        lens: choisi,
                                        intensite: force,
                                        coteMax: MoteurOptique.coteApercu)
        }
        travailApercu = travail

        Task { @MainActor in
            let image = await travail.value
            // Un rendu annulé a été remplacé par un plus récent : ni son
            // image ni son « calcul terminé » ne doivent revenir à l'écran,
            // sinon un vieux réglage écraserait le nouveau.
            guard !travail.isCancelled else { return }
            if let image {
                apercuRendu = image
            }
            calculEnCours = false
        }
    }

    // MARK: - Export

    private func enregistrer() {
        guard let donnees = donneesSource else { return }
        let choisi = objectif
        let force = Float(intensite)

        enregistrementEnCours = true
        etatEnregistrement = .repos

        Task { @MainActor in
            // L'autorisation est demandée en `.addOnly` : le studio n'a
            // jamais besoin de LIRE la photothèque (le sélecteur système
            // fournit l'image sans autorisation). Demander l'accès complet
            // pour écrire un fichier serait réclamer bien plus que nécessaire.
            let statut = await Phototheque.autorisationAjout()
            guard statut == .authorized || statut == .limited else {
                etatEnregistrement = .refuse
                enregistrementEnCours = false
                return
            }

            let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let image = MoteurOptique.rendre(donnees: donnees,
                                                       lens: choisi,
                                                       intensite: force,
                                                       coteMax: MoteurOptique.coteExport)
                else { return nil }
                // 0,92 : au-delà le fichier enfle sans gain visible, en deçà
                // les dégradés doux des disques de bokeh se mettent à
                // moirer — et ces dégradés sont tout le sujet de l'image.
                return image.jpegData(compressionQuality: 0.92)
            }.value

            guard let jpeg else {
                etatEnregistrement = .echec
                enregistrementEnCours = false
                return
            }

            let succes = await Phototheque.ajouterALaPhototheque(jpeg: jpeg)
            etatEnregistrement = succes ? .reussi : .echec
            enregistrementEnCours = false
        }
    }
}

// MARK: - Puce de sélection

/// Pastille de la barre horizontale, jumelle de celle du catalogue.
///
/// Le fond actif reste l'orange de la marque et non l'accent de l'objectif :
/// les neuf accents sont des pastels très clairs sur lesquels le texte sombre
/// perdrait tout contraste. L'accent est rappelé par la gommette, où il ne
/// porte aucune lisibilité.
private struct PuceStudio: View {

    let lens: Lens
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: lens.accent))
                .frame(width: 6, height: 6)
                // Masquée et non retirée : un retrait conditionnel changerait
                // la largeur de la puce au moment même où elle devient active,
                // et toute la rangée sursauterait.
                .opacity(active ? 0 : 1)

            Text(lens.name)
                .font(Theme.Police.puce)
                .foregroundColor(active ? Theme.Couleur.texteSurAccent : Theme.Couleur.textePuce)
                .lineLimit(1)
        }
        .padding(Theme.Espace.paddingPuce)
        .background(active ? Theme.Couleur.orange : Theme.Couleur.puce, in: Capsule())
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Curseur d'intensité

/// Curseur maison plutôt que `Slider`.
///
/// Le `Slider` système impose sa piste, sa hauteur et sa teinte unique ; le
/// site remplit le rail d'un dégradé orange → accent qui est justement le
/// signe visuel reliant le réglage à l'objectif choisi. Refaire les trois
/// formes coûte vingt lignes et rend exactement la maquette.
private struct CurseurIntensite: View {

    @Binding var valeur: Double
    @Environment(\.accentObjectif) private var accent

    var body: some View {
        HStack(spacing: Theme.Espace.ecartCurseur) {
            GeometryReader { geo in
                let pouce = Theme.Espace.diametrePouceCurseur
                // La course utile exclut le diamètre du pouce, sinon le pouce
                // déborderait du cadre aux deux extrémités et 100 % ne
                // coïnciderait pas avec le bout du rail.
                let course = max(geo.size.width - pouce, 1)
                let fraction = CGFloat(min(max(valeur, 0), 1))
                let centre = pouce / 2 + course * fraction

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Couleur.rail)
                        .frame(height: Theme.Espace.hauteurRailCurseur)

                    Capsule()
                        .fill(Theme.Fond.degradeTrait(accent: accent))
                        .frame(width: centre, height: Theme.Espace.hauteurRailCurseur)

                    Circle()
                        .fill(Color.white)
                        .frame(width: pouce, height: pouce)
                        .shadow(color: Theme.Ombre.couleurPouceCurseur,
                                radius: Theme.Ombre.rayonPouceCurseur,
                                x: 0,
                                y: Theme.Ombre.decalagePouceCurseur)
                        .offset(x: centre - pouce / 2)
                }
                .frame(height: pouce)
                // Toute la bande est saisissable, pas seulement le pouce :
                // viser un disque de 30 pt au doigt est un exercice, viser la
                // ligne ne l'est pas.
                .contentShape(Rectangle())
                .gesture(
                    // `minimumDistance: 0` fait réagir dès le contact : un
                    // simple appui sur le rail déplace le pouce, sans qu'il
                    // faille glisser d'abord.
                    DragGesture(minimumDistance: 0)
                        .onChanged { geste in
                            let brut = (geste.location.x - pouce / 2) / course
                            valeur = min(max(Double(brut), 0), 1)
                        }
                )
            }
            .frame(height: Theme.Espace.diametrePouceCurseur)

            Text("\(Int((valeur * 100).rounded())) %")
                .font(Theme.Police.valeurIntensite)
                // Chiffres à chasse fixe : la valeur ne doit pas frémir
                // pendant le glissement. Posé sur le `Text` et non sur la vue
                // encadrée : `monospacedDigit()` est une méthode de `Text`.
                .monospacedDigit()
                .foregroundColor(Theme.Couleur.texte)
                // Largeur fixe : sans elle, le passage de « 9 % » à « 100 % »
                // décalerait le rail de plusieurs points à chaque cran.
                .frame(width: Theme.Espace.largeurValeurIntensite, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Intensité")
        .accessibilityValue("\(Int((valeur * 100).rounded())) pour cent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: valeur = min(1, valeur + 0.05)
            case .decrement: valeur = max(0, valeur - 0.05)
            @unknown default: break
            }
        }
    }
}

// MARK: - Photothèque

/// Les deux seules opérations système du studio.
///
/// Elles vivent ici et non dans `MoteurOptique` à dessein : le moteur ne connaît
/// que Core Image et doit rester appelable depuis le viseur caméra, qui n'a
/// aucune raison de lier `Photos`. Écrire dans la photothèque relève de
/// l'interface, pas du rendu.
private enum Phototheque {

    /// Autorisation d'AJOUT seul. Le studio ne lit jamais la photothèque : le
    /// sélecteur système livre l'image sans la moindre autorisation. Demander
    /// l'accès complet pour écrire un fichier réclamerait bien plus que
    /// nécessaire, et c'est le genre de demande qui fait refuser tout net.
    static func autorisationAjout() async -> PHAuthorizationStatus {
        let statut = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if statut != .notDetermined { return statut }
        return await withCheckedContinuation { (suite: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { nouveau in
                suite.resume(returning: nouveau)
            }
        }
    }

    /// Écrit les octets JPEG tels quels dans la photothèque.
    ///
    /// `addResource(with:data:options:)` plutôt qu'un `UIImage` : passer par une
    /// image ferait réencoder le fichier par le système, avec ses propres
    /// réglages de qualité — l'utilisateur n'obtiendrait pas les octets qu'on a
    /// produits.
    static func ajouterALaPhototheque(jpeg: Data) async -> Bool {
        await withCheckedContinuation { (suite: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges {
                let requete = PHAssetCreationRequest.forAsset()
                requete.addResource(with: .photo, data: jpeg, options: nil)
            } completionHandler: { succes, _ in
                suite.resume(returning: succes)
            }
        }
    }
}
