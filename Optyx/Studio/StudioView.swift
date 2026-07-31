import CoreImage
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
// HONNÊTETÉ DU RENDU, qui commande tout ce fichier : un objectif ancien ne se
// voit QUE sur les points lumineux hors mise au point. Sur une photo
// d'intérieur uniforme, un vrai 58 mm f/2 ne montre rien non plus — et
// l'ancienne app, qui simulait cela « correctement », montrait donc rien du
// tout. Ici on part des HAUTES LUMIÈRES de la photo et on y dessine les mêmes
// disques que le catalogue : bord adouci par `soft`, centre creusé par `ring`,
// liseré par `rim`, frange chromatique par `fringe`, aigrettes par `spike`.
// L'état vide dit franchement quelles photos s'y prêtent, plutôt que de
// laisser l'utilisateur croire à une panne.
//
// COMPOSITION : jamais d'addition ni de mélange en alpha normal. Uniquement
// `CIScreenBlendMode`, `CIMaximumCompositing` et des `CIColorMatrix` dont la
// ligne alpha reste (0, 0, 0, 1). Sommer deux calques prémultipliés d'alpha 1
// donne un alpha 2 que la composition suivante réinterprète : c'est le bug qui
// a noirci deux fois l'ancienne app, et on supprime le mécanisme au lieu de le
// désamorcer.

// MARK: - Contexte Core Image partagé

/// Un seul contexte pour toute la durée de vie de l'app.
///
/// `CIContext` compile ses noyaux à la première utilisation et les met en
/// cache ; en recréer un à chaque mouvement du curseur rendrait chaque aperçu
/// aussi lent que le premier. Il est documenté comme utilisable depuis
/// plusieurs fils, ce qui est exactement l'usage ici (les rendus vivent dans
/// des tâches détachées).
private let contexteImages = CIContext()

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

            // Cette phrase est la contrepartie honnête du produit. Un
            // objectif ancien ne se voit que là où il y a des points lumineux
            // hors mise au point ; le dire évite la déception qu'a produite
            // l'ancienne app, qui promettait un effet sur n'importe quelle
            // image et n'en montrait aucun.
            Text("Les objectifs se voient surtout sur les scènes qui portent des points lumineux — guirlandes, ville de nuit, reflets sur l'eau, contre-jour.")
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
                MoteurStudio.imageReduite(donnees: donnees, coteMax: MoteurStudio.coteApercu)
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
            return MoteurStudio.rendre(donnees: donnees,
                                       lens: choisi,
                                       intensite: force,
                                       coteMax: MoteurStudio.coteApercu)
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
            let statut = await MoteurStudio.autorisationAjout()
            guard statut == .authorized || statut == .limited else {
                etatEnregistrement = .refuse
                enregistrementEnCours = false
                return
            }

            let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let image = MoteurStudio.rendre(donnees: donnees,
                                                      lens: choisi,
                                                      intensite: force,
                                                      coteMax: MoteurStudio.coteExport)
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

            let succes = await MoteurStudio.ajouterALaPhototheque(jpeg: jpeg)
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

// MARK: - Moteur de rendu

/// Le rendu photo, entièrement en Core Image.
///
/// Pourquoi pas le shader Metal du catalogue : celui-ci DESSINE un champ de
/// particules synthétiques, il ne transforme pas une image existante. Le
/// principe « un seul shader » est tenu autrement, et plus honnêtement — les
/// mêmes quatorze paramètres de `BokehParams` pilotent ici les mêmes traits
/// visuels (bord adouci par `soft`, centre creusé par `ring`, liseré par
/// `rim`, frange par `fringe`, aigrettes par `spike`, voile par `haze`), et
/// les disques naissent des hautes lumières de la photo comme ils naissent des
/// points lumineux de la scène.
///
/// Toutes les longueurs sont dérivées du plus grand côté de l'image. C'est ce
/// qui garantit que l'aperçu à 1200 px et l'export à 3200 px sont la MÊME
/// image à l'échelle près : l'ancienne app exprimait ses rayons en pixels, et
/// l'export ne ressemblait pas à ce qui avait été validé à l'écran.
private enum MoteurStudio {

    /// Aperçu réduit : au-delà, chaque mouvement du curseur ferait attendre
    /// l'utilisateur, ce qui revient à lui interdire d'explorer.
    static let coteApercu: CGFloat = 1200
    /// Export. 3200 px sur le plus grand côté suffit à un tirage A3 et garde
    /// la morphologie (l'étape la plus coûteuse) dans des durées acceptables.
    static let coteExport: CGFloat = 3200

    // MARK: Préparation

    /// Décode et réduit, en normalisant l'orientation.
    ///
    /// Le passage par `UIGraphicsImageRenderer` n'est pas un détour : c'est
    /// `UIImage.draw(in:)` qui applique l'orientation EXIF. Un `CIImage(data:)`
    /// direct livrerait les pixels bruts, et toutes les photos prises en
    /// portrait sortiraient couchées — panne classique et parfaitement
    /// silencieuse.
    static func imageReduite(donnees: Data, coteMax: CGFloat) -> UIImage? {
        guard let source = UIImage(data: donnees) else { return nil }

        let largeurPixels = source.size.width * source.scale
        let hauteurPixels = source.size.height * source.scale
        let plusGrandCote = max(largeurPixels, hauteurPixels)
        guard plusGrandCote > 0 else { return nil }

        // Jamais d'agrandissement : interpoler une petite image ne créerait
        // aucun détail et multiplierait le coût du filtrage.
        let facteur = min(1, coteMax / plusGrandCote)
        let cible = CGSize(width: max(1, (largeurPixels * facteur).rounded()),
                           height: max(1, (hauteurPixels * facteur).rounded()))

        let format = UIGraphicsImageRendererFormat.default()
        // Échelle 1 : on raisonne en pixels, pas en points. Laisser l'échelle
        // de l'écran multiplierait silencieusement la taille par 3 sur un
        // iPhone Pro et ferait mentir `coteMax`.
        format.scale = 1
        // Opaque : une photo n'a pas de transparence, et un canal alpha inutile
        // est une invitation de plus au piège du prémultiplié.
        format.opaque = true

        return UIGraphicsImageRenderer(size: cible, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: cible))
        }
    }

    /// Chaîne complète : décodage, réduction, effet optique, retour en `UIImage`.
    /// Renvoie `nil` si la tâche a été annulée entre deux étapes — l'appelant
    /// jette alors le résultat sans rien afficher.
    static func rendre(donnees: Data, lens: Lens, intensite: Float, coteMax: CGFloat) -> UIImage? {
        guard let reduite = imageReduite(donnees: donnees, coteMax: coteMax) else { return nil }
        if Task.isCancelled { return nil }

        guard let base = CIImage(image: reduite) else { return nil }
        let cadre = base.extent
        guard cadre.width > 0, cadre.height > 0 else { return nil }

        let resultat = appliquer(lens: lens, intensite: intensite, sur: base, cadre: cadre)
        if Task.isCancelled { return nil }

        guard let cg = contexteImages.createCGImage(resultat, from: cadre) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    // MARK: Graphe d'effets

    private static func appliquer(lens: Lens,
                                  intensite: Float,
                                  sur base: CIImage,
                                  cadre: CGRect) -> CIImage {

        let k = min(max(intensite, 0), 1)
        let p = lens.bokeh

        // Sous 2 % d'intensité l'image renvoyée est la photo nue : recalculer
        // une douzaine de filtres pour un résultat identique au pixel près
        // serait du temps volé à l'utilisateur qui balaie le curseur.
        if k < 0.02 { return base }

        let grandCote = max(cadre.width, cadre.height)

        // Rayon du cercle de confusion, en fraction du cadre. 1,8 % du grand
        // côté à `size` = 1 : c'est le compromis entre « on ne voit rien »
        // (le reproche fondateur) et une bouillie de taches. Le facteur
        // (0,35 + 0,65·k) est EXACTEMENT celui du renderer du catalogue, pour
        // que le curseur agisse pareil des deux côtés.
        let rayon = grandCote * 0.018 * CGFloat(p.size) * CGFloat(0.35 + 0.65 * k)
        // Plafond : au-delà, `CIMorphologyMaximum` devient très lent sans que
        // l'image y gagne — les disques se recouvrent alors tous.
        let rayonDisque = min(max(rayon, 2), 90)

        // 1. HAUTES LUMIÈRES. Seuil bas (0,58) puis renormalisation : c'est le
        // seul contenu de la photo sur lequel un objectif ancien se manifeste.
        // Le reste de l'image ne doit surtout PAS être touché — flouter le
        // sujet est ce qui donnait à l'ancienne app son air de filtre bon
        // marché.
        let seuil: CGFloat = 0.58
        var hautes = base
            .applyingFilter("CIColorControls", parameters: [
                "inputBrightness": -seuil,
                "inputSaturation": 1.2,
                "inputContrast": 1.0
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])

        // ENTOURAGE SOMBRE EXIGÉ — la protection qui manquait, et sans laquelle
        // ce moteur répète le défaut le plus reproché à l'ancienne app :
        // des anneaux dessinés sur les nuages, des liserés sur les murs clairs.
        //
        // Le seuil de luminance seul ne distingue pas un POINT de lumière d'une
        // large SURFACE lumineuse : un ciel blanc le franchit tout entier, se
        // fait dilater, et l'écran qui suit repeint le ciel par-dessus lui-même.
        // Or un vrai objectif ne fabrique un disque de bokeh que pour une source
        // ponctuelle — c'est-à-dire une source ENTOURÉE d'ombre.
        //
        // `CIMorphologyMinimum` érode : chaque pixel prend le minimum de son
        // voisinage. Au centre d'une grande surface claire il reste clair ; à
        // portée d'une zone sombre il s'effondre. L'inverse de cette érosion
        // vaut donc « il y a du sombre alentour », et sert de laissez-passer.
        // Le rayon suit celui du disque : c'est bien à l'échelle du bokeh à
        // venir qu'il faut juger si la source est isolée.
        let rayonEntourage = Float(min(90, max(3, rayonDisque * 0.75)))
        let entourage = base
            .clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [
                "inputRadius": rayonEntourage
            ])
            .cropped(to: cadre)
            .applyingFilter("CIColorControls", parameters: [
                "inputBrightness": 0, "inputSaturation": 0, "inputContrast": 1
            ])
        // Rampe douce plutôt que seuil net : une frontière franche se lirait
        // elle-même comme un contour dans l'image.
        let laissezPasser = entourage
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -2.2, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: -2.2, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: -2.2, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 1.0, y: 1.0, z: 1.0, w: 0)
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
        // Multiplication et non addition : elle ne peut que RETIRER des points
        // candidats, jamais en inventer, et l'alpha reste borné à 1.
        hautes = hautes.applyingFilter("CIMultiplyCompositing", parameters: [
            "inputBackgroundImage": laissezPasser
        ])

        // Renormalisation ET teinte de l'objectif en une seule matrice. La
        // ligne alpha reste (0, 0, 0, 1) : c'est la règle non négociable de ce
        // fichier, une matrice qui touche à l'alpha rouvre le bug de
        // l'ancienne app.
        let gain = 1 / (1 - Float(seuil))
        let teinte = composantes(hex: lens.palette.first ?? lens.accent)
        // Dosage : à faible intensité la teinte de l'objectif s'efface, à
        // pleine intensité elle colore franchement les disques — c'est ce qui
        // distingue un Helios vert-jaune d'un Noct-Nikkor bleuté.
        let dose = 0.55 * k
        hautes = hautes.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(gain * melange(1, teinte.0, dose)), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(gain * melange(1, teinte.1, dose)), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(gain * melange(1, teinte.2, dose)), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])

        // 2. DISQUES. La dilatation morphologique étale chaque point lumineux
        // en un disque de rayon constant — c'est littéralement le cercle de
        // confusion. Le flou de disque qui suit adoucit son bord : `soft`
        // pilote la largeur de la transition, de 0,10 (bord franc du
        // Summicron) à 0,72 (halo évanescent du Dream Lens).
        let etale = hautes
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [
                "inputRadius": Float(rayonDisque)
            ])
        var couche = etale
            .applyingFilter("CIDiscBlur", parameters: [
                "inputRadius": Float(max(1, rayonDisque * CGFloat(0.10 + 0.55 * p.soft)))
            ])
            .cropped(to: cadre)

        // 3. ANNEAU (bulles de savon). L'aberration sphérique non corrigée
        // d'un triplet vide le centre du disque. On le reproduit par la
        // DIFFÉRENCE entre le disque plein et un disque plus petit : là où les
        // deux sont pleins (le centre) la différence s'annule, il ne reste que
        // la couronne. `ring` ne dépend pas de l'intensité — une bulle de
        // savon reste une bulle de savon, c'est un trait structurel.
        if p.ring > 0.01 {
            let interieur = hautes
                .clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: [
                    "inputRadius": Float(max(1, rayonDisque * 0.62))
                ])
                .applyingFilter("CIDiscBlur", parameters: [
                    "inputRadius": Float(max(1, rayonDisque * 0.22))
                ])
                .cropped(to: cadre)

            let anneau = couche.applyingFilter("CIDifferenceBlendMode", parameters: [
                "inputBackgroundImage": interieur
            ])
            // Maximum et non addition : le maximum laisse l'alpha strictement
            // intact (max(1, 1) = 1) là où l'addition le porterait à 2.
            couche = mixerParMaximum(couche, poids: CGFloat(1 - p.ring),
                                     avec: anneau, poids: CGFloat(p.ring),
                                     cadre: cadre)
        }

        // 4. LISERÉ. L'aberration sphérique sous-corrigée concentre les rayons
        // marginaux sur le pourtour. Même construction que l'anneau, mais avec
        // un écart de rayon bien plus fin : c'est un trait, pas une couronne.
        if p.rim > 0.02 {
            let creux = couche
                .clampedToExtent()
                .applyingFilter("CIDiscBlur", parameters: [
                    "inputRadius": Float(max(1, rayonDisque * 0.30))
                ])
                .cropped(to: cadre)
            let lisere = couche.applyingFilter("CIDifferenceBlendMode", parameters: [
                "inputBackgroundImage": creux
            ])
            couche = ecran(couche, avec: attenuer(lisere, facteur: CGFloat(p.rim * k)))
        }

        // 5. FRANGE CHROMATIQUE. Le même disque évalué à trois échelles : le
        // rouge déborde, le bleu rentre, d'où le liseré magenta au dehors et
        // cyan au dedans. `fringe` ne dépasse jamais 0,075 dans le catalogue —
        // c'est subtil, et c'est voulu.
        if p.fringe > 0.004 {
            let ecart = CGFloat(p.fringe * k) * 0.09
            let centre = CGPoint(x: cadre.midX, y: cadre.midY)
            let rouge = canal(couche, rouge: 1, vert: 0, bleu: 0)
                .transformed(by: echelleAutourDe(centre, facteur: 1 + ecart))
                .cropped(to: cadre)
            let bleu = canal(couche, rouge: 0, vert: 0, bleu: 1)
                .transformed(by: echelleAutourDe(centre, facteur: 1 - ecart))
                .cropped(to: cadre)
            couche = ecran(ecran(couche, avec: rouge), avec: bleu)
        }

        // 6. AIGRETTES. Deux flous de mouvement croisés : la SOMME des deux
        // bandes fait une croix, alors que leur produit ne laisserait que
        // l'intersection, c'est-à-dire un point.
        if p.spike > 0.02 {
            let longueur = Float(rayonDisque * 2.2)
            let horizontale = hautes.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [
                    "inputRadius": longueur, "inputAngle": Float(0)
                ])
                .cropped(to: cadre)
            let verticale = hautes.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [
                    "inputRadius": longueur, "inputAngle": Float.pi / 2
                ])
                .cropped(to: cadre)
            let croix = ecran(horizontale, avec: verticale)
            couche = ecran(couche, avec: attenuer(croix, facteur: CGFloat(p.spike * k) * 0.8))
        }

        // 7. TOURBILLON. Un vortex appliqué au SEUL calque optique, screené
        // par-dessus lui : les disques ne se déplacent pas, ils s'accompagnent
        // d'une traînée en arc. Déplacer les disques eux-mêmes les décollerait
        // de la lumière qui les a engendrés, et l'image deviendrait fausse au
        // premier regard.
        if p.swirl > 0.02 {
            let tourbillon = couche
                .clampedToExtent()
                .applyingFilter("CIVortexDistortion", parameters: [
                    "inputCenter": CIVector(x: cadre.midX, y: cadre.midY),
                    "inputRadius": Float(grandCote * 0.95),
                    "inputAngle": Float(p.swirl * k) * 0.42
                ])
                .cropped(to: cadre)
            couche = ecran(couche, avec: attenuer(tourbillon, facteur: CGFloat(p.swirl * k) * 0.75))
        }

        // 8. VOILE DE DIFFUSION. La lumière parasite des verres anciens non
        // traités : un halo LARGE et FAIBLE autour des hautes lumières. Ce
        // n'est pas un flou — la netteté du sujet ne doit pas bouger d'un
        // pixel, sans quoi on retombe sur le filtre bon marché.
        if p.haze > 0.01 {
            let voile = hautes
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [
                    "inputRadius": Float(max(2, rayonDisque * 2.4))
                ])
                .cropped(to: cadre)
            couche = ecran(couche, avec: attenuer(voile, facteur: CGFloat(min(1, p.haze * 2.2 * k))))
        }

        // 9. ŒIL DE CHAT. Le vignettage mécanique du barillet tronque les
        // disques périphériques. À l'échelle de l'image entière, cela se lit
        // comme un affaiblissement progressif du bokeh vers les bords — et
        // c'est appliqué au calque optique SEUL : assombrir la photo elle-même
        // serait un effet de style que personne n'a demandé.
        if p.cat > 0.02 {
            couche = couche.applyingFilter("CIVignetteEffect", parameters: [
                "inputCenter": CIVector(x: cadre.midX, y: cadre.midY),
                "inputRadius": Float(grandCote * 0.48),
                "inputIntensity": Float(p.cat * k) * 0.9,
                "inputFalloff": Float(0.5)
            ])
        }

        // 10. COMPOSITION. `CIScreenBlendMode` : il n'assombrit jamais et
        // laisse l'alpha à 1 (1 + 1 − 1·1 = 1). L'addition, elle, porterait
        // l'alpha à 2 et la composition suivante réinterpréterait le tout
        // comme du prémultiplié — l'image sortirait noircie deux fois, ce qui
        // est exactement la panne qui a coulé la version précédente.
        let force = CGFloat(0.55 + 0.45 * k) * CGFloat(p.opacity)
        var image = ecran(base, avec: attenuer(couche, facteur: force))

        // 11. GRAIN. Réservé au rendu ciné de l'Angénieux (`grain` = 1 chez
        // lui seul). En lumière douce plutôt qu'en incrustation : le grain
        // doit texturer les demi-teintes sans écraser ni les noirs ni les
        // hautes lumières.
        if p.grain > 0.01, let bruit = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let amplitude = CGFloat(p.grain * k) * 0.32
            let voileGrain = bruit
                .cropped(to: cadre)
                // Désaturation puis compression autour de 0,5 : un bruit
                // coloré virerait la photo au bruit vidéo, et un bruit non
                // recentré éclaircirait ou assombrirait toute l'image.
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: amplitude, y: amplitude, z: amplitude, w: 0),
                    "inputGVector": CIVector(x: amplitude, y: amplitude, z: amplitude, w: 0),
                    "inputBVector": CIVector(x: amplitude, y: amplitude, z: amplitude, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: (1 - amplitude * 3) / 2,
                                                y: (1 - amplitude * 3) / 2,
                                                z: (1 - amplitude * 3) / 2,
                                                w: 1)
                ])
            image = voileGrain.applyingFilter("CISoftLightBlendMode", parameters: [
                "inputBackgroundImage": image
            ])
        }

        // Recadrage final obligatoire : les flous et la dilatation ont agrandi
        // l'étendue, et un `createCGImage` sur une étendue élargie livrerait
        // une image plus grande que la photo, bordée de halo.
        return image.cropped(to: cadre)
    }

    // MARK: Briques de composition

    /// Superposition en écran. Le seul mode de mélange autorisé pour poser un
    /// calque lumineux sur l'image : il n'assombrit jamais et laisse l'alpha
    /// des deux calques à 1.
    private static func ecran(_ fond: CIImage, avec calque: CIImage) -> CIImage {
        calque.applyingFilter("CIScreenBlendMode", parameters: [
            "inputBackgroundImage": fond
        ])
    }

    /// Atténue un calque lumineux SANS toucher à son alpha.
    private static func attenuer(_ image: CIImage, facteur: CGFloat) -> CIImage {
        let f = min(max(facteur, 0), 4)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    /// Fondu entre deux calques lumineux par maximum pondéré.
    ///
    /// Un vrai fondu linéaire demanderait une addition, donc un alpha à 2. Le
    /// maximum donne le même résultat aux deux extrémités (poids 0 ou 1) et,
    /// entre les deux, une transition parfaitement acceptable sur des calques
    /// qui ne contiennent que de la lumière.
    private static func mixerParMaximum(_ a: CIImage, poids poidsA: CGFloat,
                                        avec b: CIImage, poids poidsB: CGFloat,
                                        cadre: CGRect) -> CIImage {
        attenuer(b, facteur: poidsB)
            .applyingFilter("CIMaximumCompositing", parameters: [
                "inputBackgroundImage": attenuer(a, facteur: poidsA)
            ])
            .cropped(to: cadre)
    }

    /// Isole un canal, alpha inchangé. Sert à la frange chromatique.
    private static func canal(_ image: CIImage, rouge: CGFloat, vert: CGFloat, bleu: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: rouge, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: vert, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: bleu, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    /// Homothétie autour d'un point. Une `CGAffineTransform(scaleX:y:)` nue
    /// est centrée sur l'origine, en bas à gauche de l'image : appliquée
    /// telle quelle, la frange dériverait en diagonale au lieu de s'ouvrir
    /// symétriquement autour du centre du cadre.
    private static func echelleAutourDe(_ centre: CGPoint, facteur: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: centre.x, y: centre.y)
            .scaledBy(x: facteur, y: facteur)
            .translatedBy(x: -centre.x, y: -centre.y)
    }

    private static func melange(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    /// Hex du catalogue → composantes sRGB.
    ///
    /// L'analyse est refaite ici plutôt qu'empruntée à `Color(hex:)` du
    /// thème : celui-ci produit une `Color` SwiftUI, dont on ne peut pas
    /// ressortir les composantes de façon fiable.
    private static func composantes(hex: String) -> (Float, Float, Float) {
        var texte = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if texte.hasPrefix("#") { texte.removeFirst() }
        if texte.count == 3 {
            var doublee = ""
            for caractere in texte {
                doublee.append(caractere)
                doublee.append(caractere)
            }
            texte = doublee
        }
        guard texte.count == 6, let valeur = UInt32(texte, radix: 16) else {
            // Blanc plutôt que noir : une teinte de repli neutre laisse les
            // disques visibles, un noir les éteindrait et passerait pour un
            // bug de rendu.
            return (1, 1, 1)
        }
        return (Float((valeur >> 16) & 0xFF) / 255,
                Float((valeur >> 8) & 0xFF) / 255,
                Float(valeur & 0xFF) / 255)
    }

    // MARK: Photothèque

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
    /// `addResource(with:data:options:)` plutôt qu'un `UIImage` : passer par
    /// une image ferait réencoder le fichier par le système, avec ses propres
    /// réglages de qualité — l'utilisateur n'obtiendrait pas les octets qu'on
    /// a produits.
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
