import CoreImage
import SwiftUI
import UIKit

// Écran de prise de vue : le viseur, le choix de l'objectif, le déclencheur.
//
// CE FICHIER NE CALCULE RIEN et ne parle jamais à AVFoundation. Tout le rendu
// vit dans `MoteurOptique`, toute la capture dans `ControleurCamera`, tout
// l'affichage dans `RenduViseur` (Camera/VueApercu.swift). Ce qui reste ici est
// strictement de l'interface — et c'est volontaire : le viseur doit montrer
// EXACTEMENT ce que le fichier enregistré contiendra, ce qui n'est tenable que
// si aucune vue n'a le droit d'ajouter sa touche personnelle.
//
// Le style est repris tel quel du studio (mêmes constantes de `Theme`, mêmes
// puces, même curseur) : ce sont les deux faces d'un même geste, un utilisateur
// qui passe de l'un à l'autre ne doit pas avoir l'impression de changer d'app.
//
// Le contrôleur ne connaît PAS l'afficheur : il publie ses trames par la
// fermeture `surTrameViseur`. C'est cette vue qui relie les deux, en trois
// lignes, et c'est la raison pour laquelle `ControleurCamera` ne référence ni
// MetalKit ni SwiftUI.

struct VueCamera: View {

    /// Sortie de secours quand la caméra est refusée ou absente : bascule vers
    /// le studio. Un refus d'autorisation ne doit jamais laisser l'utilisateur
    /// dans une impasse — l'import de photos, lui, marche toujours.
    /// Optionnelle pour que la vue reste utilisable seule (aperçus, tests).
    var allerAuStudio: (() -> Void)?

    /// Initialiseur EXPLICITE, et non l'initialiseur mémberwise synthétisé :
    /// dès qu'une structure possède un stocké `private` — ici tout l'état de la
    /// vue — Swift restreint le mémberwise au fichier courant, et
    /// `VueCamera(allerAuStudio:)` deviendrait inappelable depuis `RootView`.
    /// La panne n'est pas évidente à lire dans le diagnostic du compilateur ;
    /// ces trois lignes l'évitent définitivement.
    init(allerAuStudio: (() -> Void)? = nil) {
        self.allerAuStudio = allerAuStudio
    }

    @StateObject private var camera = ControleurCamera()

    /// L'afficheur, détenu par la VUE et non par le contrôleur.
    ///
    /// `@StateObject` garantit une instance unique pour toute la durée de
    /// l'écran : en `@State`, SwiftUI en construirait une neuve à chaque
    /// reconstruction du corps, et le lien avec la `MTKView` serait recréé pour
    /// rien plusieurs fois par seconde.
    @StateObject private var viseur = RenduViseur()

    @Environment(\.scenePhase) private var phaseScene

    @State private var objectif: Lens = Lens.catalog[0]

    /// Curseur d'intensité dans [0, 1]. `Double` parce que c'est le type naturel
    /// d'un binding SwiftUI ; la conversion en `Float` a lieu au seul moment où
    /// la valeur part vers le contrôleur.
    @State private var intensite: Double = 0.8

    /// Vrai tant que l'onglet est à l'écran. Sans ce drapeau, un retour au
    /// premier plan relancerait la session même si l'utilisateur est entre-temps
    /// passé sur un autre onglet — la caméra chaufferait pour personne.
    @State private var ongletVisible = false

    /// Jeton de la temporisation qui efface la confirmation de capture. Il évite
    /// qu'une ancienne temporisation efface un message plus récent : deux
    /// captures rapprochées feraient sinon disparaître la seconde au bout d'une
    /// demi-seconde.
    @State private var jetonRetour = UUID()

    // MARK: Corps

    var body: some View {
        ZStack {
            // Noir pur sous tout le reste, encoche et barre d'accueil comprises.
            Theme.Couleur.fond.ignoresSafeArea()

            vueDuViseur

            voileAttente

            commandes

            panneauIndisponibilite
        }
        // La cascade `--accent` du site, comme dans le studio : posée une fois
        // ici, lue par le curseur et la légende.
        .environment(\.accentObjectif, Color(hex: objectif.accent))
        .onAppear {
            ongletVisible = true
            brancherViseur()
            // Les réglages sont poussés AVANT le démarrage : sans cela, les
            // premières trames sortiraient avec l'objectif par défaut du
            // contrôleur, et le viseur clignerait au premier changement.
            camera.regler(lens: objectif, intensite: Float(intensite))
            camera.demarrer()
        }
        .onDisappear {
            ongletVisible = false
            camera.arreter()
            // On coupe le fil dans les deux sens : plus de trames publiées, et
            // l'image figée de la dernière est oubliée. Sans ce `vider()`, le
            // retour sur l'onglet montrerait une fraction de seconde la scène
            // de la fois précédente.
            camera.surTrameViseur = nil
            viseur.vider()
        }
        .onChange(of: objectif) { _, nouvel in
            camera.regler(lens: nouvel, intensite: Float(intensite))
        }
        .onChange(of: intensite) { _, nouvelle in
            // Aucun anti-rebond ici, contrairement au studio : le viseur ne
            // relance pas de rendu, il lit la valeur courante à la trame
            // suivante. Le curseur peut donc émettre autant qu'il veut.
            camera.regler(lens: objectif, intensite: Float(nouvelle))
        }
        .onChange(of: phaseScene) { _, nouvelle in
            if nouvelle == .active {
                if ongletVisible {
                    brancherViseur()
                    camera.demarrer()
                }
            } else if nouvelle == .background {
                camera.arreter()
            }
        }
        .onChange(of: camera.retourCapture) { _, nouveau in
            planifierEffacementRetour(nouveau != nil)
        }
    }

    // MARK: Viseur

    private var vueDuViseur: some View {
        VueApercu(rendu: viseur)
            // Plein cadre, jusque sous l'encoche : le viseur est l'écran.
            // L'image y est cadrée en aspect-fit, donc rien n'est rogné — ce
            // sont les bandes noires qui vont sous les bords, pas la photo.
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    /// Relie le contrôleur à l'afficheur.
    ///
    /// La fermeture est appelée sur la file vidéo du contrôleur, jamais sur le
    /// fil principal : `publier(_:)` est écrit pour cela (recopie sous verrou,
    /// puis demande de redessin sur le fil principal). Capture FAIBLE de
    /// l'afficheur — le contrôleur retient la fermeture, et une capture forte
    /// ferait survivre l'afficheur à l'écran qui le possède.
    private func brancherViseur() {
        let rendu = viseur
        camera.surTrameViseur = { [weak rendu] image in
            rendu?.publier(image)
        }
    }

    /// Voile posé tant qu'aucune trame n'est arrivée, et pendant une
    /// interruption. Sans lui, l'ouverture de l'onglet montre un cadre noir muet
    /// pendant la seconde que prend `startRunning()`, et l'utilisateur croit
    /// l'app plantée.
    @ViewBuilder
    private var voileAttente: some View {
        if camera.etat == .interrompue {
            message(
                symbole: "exclamationmark.triangle",
                texte: "Caméra momentanément indisponible. Le viseur reprendra tout seul."
            )
        } else if camera.etat == .enMarche && !camera.premiereTrameRecue {
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.Couleur.texte)
                Text("Ouverture du viseur…")
                    .font(Theme.Police.meta)
                    .tracking(Theme.Tracking.meta)
                    .foregroundColor(Theme.Couleur.texteAttenue)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Couleur.fond.ignoresSafeArea())
        } else if !RenduViseur.metalDisponible {
            // Cas dégradé honnête : la capture peut très bien fonctionner, mais
            // rien ne peut s'afficher. Le dire vaut mieux qu'un rectangle noir
            // que l'utilisateur prendra pour une panne de l'appareil photo.
            message(
                symbole: "rectangle.slash",
                texte: "L'aperçu en direct n'est pas disponible sur cet appareil."
            )
        }
    }

    private func message(symbole: String, texte: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbole)
                .font(.system(size: 24, weight: .regular))
                .foregroundColor(Theme.Couleur.orange)
            Text(texte)
                .font(Theme.Police.recit)
                .lineSpacing(Theme.Interligne.recit)
                .foregroundColor(Theme.Couleur.texteSecondaire)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: 380)
        .background(Color.black.opacity(0.62),
                    in: RoundedRectangle(cornerRadius: Theme.Rayon.carte, style: .continuous))
        .padding(.horizontal, Theme.Espace.margeSection)
    }

    // MARK: Commandes

    private var commandes: some View {
        VStack(spacing: 0) {
            barreHaute
            Spacer(minLength: 0)
            panneauBas
        }
    }

    /// « v2.1 (42) » — version commerciale et numéro de build, lus dans le
    /// bundle. Le numéro de build est attribué par Xcode Cloud à l'archive :
    /// c'est lui qui identifie une livraison sans ambiguïté, la version
    /// commerciale seule ne distinguant pas deux builds successifs.
    static var versionCourte: String {
        let infos = Bundle.main.infoDictionary
        let court = infos?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infos?["CFBundleVersion"] as? String ?? "?"
        return "v\(court) (\(build))"
    }

    private var barreHaute: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("VISEUR")
                .font(Theme.Police.marque)
                .tracking(Theme.Tracking.marque)
                .foregroundColor(Theme.Couleur.orange)
                .shadow(color: Theme.Ombre.couleurTitreSurScene,
                        radius: Theme.Ombre.rayonTitreSurScene,
                        x: 0,
                        y: Theme.Ombre.decalageTitreSurScene)

            // VERSION AFFICHÉE DANS LE VISEUR, et pas seulement au catalogue.
            //
            // Ce n'est pas un ornement, c'est un instrument de diagnostic. Il
            // s'est écoulé une douzaine d'allers-retours pendant lesquels un
            // rendu était jugé sur une version de TestFlight antérieure aux
            // correctifs, sans que personne — ni l'auteur, ni moi — puisse le
            // savoir. Un correctif livré plus vite qu'Apple ne distribue est
            // indiscernable d'un correctif qui ne marche pas.
            //
            // La version est ici parce que c'est ICI qu'on juge le rendu : la
            // lire suppose sinon de quitter l'écran qu'on est en train
            // d'évaluer. Elle doit CHANGER à chaque livraison, faute de quoi
            // elle ne prouve rien.
            Text(Self.versionCourte)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.Couleur.orange.opacity(0.65))

            Spacer(minLength: 0)

            Button {
                camera.basculerCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.Couleur.texte)
                    .frame(width: 42, height: 42)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(camera.etat != .enMarche)
            .opacity(camera.etat == .enMarche ? 1 : 0.4)
            .accessibilityLabel(camera.frontale
                                ? "Passer à la caméra arrière"
                                : "Passer à la caméra avant")
        }
        .padding(.horizontal, Theme.Espace.margeSection)
        .padding(.top, 6)
    }

    private var panneauBas: some View {
        VStack(alignment: .leading, spacing: 0) {
            rangeeDePuces
            legendeObjectif
            curseur
            noteRetour
            declencheur
        }
        .frame(maxWidth: Theme.Espace.largeurMax)
        .frame(maxWidth: .infinity)
        // Voile dégradé sous les commandes : posé sur l'image elle-même, du
        // texte clair sur un ciel de plage en plein soleil serait illisible.
        // Il monte progressivement pour ne pas couper le cadrage d'un trait net.
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: Choix de l'objectif

    /// Jumelle exacte de la rangée du studio : mêmes puces, mêmes espacements,
    /// même recentrage automatique. Les deux écrans doivent se lire comme un
    /// seul geste.
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
                            PuceObjectifViseur(lens: candidat, active: candidat.id == objectif.id)
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
                withAnimation(.easeInOut(duration: 0.28)) {
                    defilement.scrollTo(nouvel.id, anchor: .center)
                }
            }
        }
        .accessibilityLabel("Choisir un objectif")
    }

    private var legendeObjectif: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(objectif.name)
                .font(Theme.Police.signatureLegende)
                .foregroundColor(Theme.Couleur.texte)

            Text(objectif.focal)
                .font(Theme.Police.focale)
                .foregroundColor(Color(hex: objectif.accent))

            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, Theme.Espace.margeSection)
    }

    private var curseur: some View {
        HStack(spacing: 12) {
            Text("INTENSITÉ")
                .font(Theme.Police.meta)
                .tracking(Theme.Tracking.meta)
                .foregroundColor(Theme.Couleur.texteAttenue)
                .fixedSize()

            CurseurIntensiteViseur(valeur: $intensite)
        }
        .padding(.horizontal, Theme.Espace.margeSection)
        .padding(.top, 10)
    }

    // MARK: Déclencheur

    private var declencheur: some View {
        Button {
            camera.declencher()
        } label: {
            ZStack {
                // Anneau extérieur fixe + pastille intérieure : la géométrie de
                // l'app Appareil photo, que la main connaît déjà. Réinventer la
                // forme du déclencheur ne ferait gagner personne.
                Circle()
                    .strokeBorder(Theme.Couleur.texte.opacity(0.92), lineWidth: 4)
                    .frame(width: 76, height: 76)

                Circle()
                    .fill(Theme.Couleur.orange)
                    .frame(width: 60, height: 60)
                    .opacity(camera.captureEnCours ? 0.45 : 1)

                if camera.captureEnCours {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Theme.Couleur.texteSurAccent)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(camera.captureEnCours || camera.etat != .enMarche)
        // Le déclencheur reste EN PLACE quand il est inactif, simplement
        // estompé : le faire disparaître ferait sauter tout le bas de l'écran
        // au moment précis où l'utilisateur vise.
        .opacity(camera.etat == .enMarche && !camera.captureEnCours ? 1 : 0.45)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .accessibilityLabel("Déclencher")
    }

    // MARK: Confirmation de capture

    /// Retour visuel après capture. Jamais de silence : une photo qui part sans
    /// rien afficher est le défaut exact qu'a connu l'ancienne app — le
    /// déclencheur « capturait » et rien n'arrivait dans la photothèque.
    @ViewBuilder
    private var noteRetour: some View {
        if let retour = camera.retourCapture {
            HStack(spacing: 8) {
                if retour == .enregistree {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.Couleur.orange)
                    Text("Enregistré dans la photothèque.")
                        .foregroundColor(Theme.Couleur.texteSecondaire)
                } else if retour == .refusePhototheque {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundColor(Theme.Couleur.orange)
                    Text("Optyx n'est pas autorisé à ajouter des photos. Réglages → Optyx → Photos.")
                        .foregroundColor(Theme.Couleur.texteSecondaire)
                } else {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundColor(Theme.Couleur.orange)
                    Text("La prise de vue a échoué. Réessayez.")
                        .foregroundColor(Theme.Couleur.texteSecondaire)
                }
                Spacer(minLength: 0)
            }
            .font(Theme.Police.copyright)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Espace.margeSection)
            .padding(.top, 10)
            .transition(.opacity)
        }
    }

    /// Efface la confirmation au bout de trois secondes.
    ///
    /// Trois secondes, et non une alerte à congédier : la confirmation doit se
    /// voir sans jamais interrompre l'enchaînement viser → déclencher → viser.
    private func planifierEffacementRetour(_ actif: Bool) {
        guard actif else { return }
        let jeton = UUID()
        jetonRetour = jeton
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard jetonRetour == jeton else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                camera.accuserRetour()
            }
        }
    }

    // MARK: Panneaux d'indisponibilité

    /// Jamais d'écran noir muet : chaque impasse dit ce qui se passe et ce qu'on
    /// peut y faire. Les deux cas sont DISTINCTS — envoyer dans les Réglages un
    /// utilisateur de simulateur, qui n'y trouvera aucune caméra, serait une
    /// fausse piste.
    @ViewBuilder
    private var panneauIndisponibilite: some View {
        if camera.etat == .refuse {
            panneau(
                symbole: "camera.badge.ellipsis",
                titre: "Optyx n'a pas accès à l'appareil photo",
                message: "Le viseur ne peut pas s'ouvrir sans cette autorisation. Elle se règle dans Réglages → Optyx → Appareil photo.",
                actionReglages: true
            )
        } else if camera.etat == .indisponible {
            panneau(
                symbole: "camera.on.rectangle",
                titre: "Aucun appareil photo disponible",
                message: "Cet appareil ne fournit pas de caméra utilisable. Le studio, lui, applique les mêmes objectifs aux photos de votre photothèque.",
                actionReglages: false
            )
        }
    }

    private func panneau(symbole: String,
                         titre: String,
                         message: String,
                         actionReglages: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbole)
                .font(.system(size: 30, weight: .regular))
                .foregroundColor(Theme.Couleur.orange)

            Text(titre)
                .font(Theme.Police.signatureCarte)
                .foregroundColor(Theme.Couleur.texte)
                .multilineTextAlignment(.center)

            Text(message)
                .font(Theme.Police.recit)
                .lineSpacing(Theme.Interligne.recit)
                .foregroundColor(Theme.Couleur.texteAttenue)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if actionReglages {
                Button {
                    ouvrirReglages()
                } label: {
                    Text("Ouvrir les réglages")
                        .font(Theme.Police.cta)
                        .foregroundColor(Theme.Couleur.texteSurAccent)
                        .padding(Theme.Espace.paddingCTA)
                        .background(Theme.Couleur.orange, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            if let allerAuStudio {
                Button {
                    allerAuStudio()
                } label: {
                    Text("Aller au studio")
                        .font(Theme.Police.puce)
                        .foregroundColor(Theme.Couleur.textePuce)
                        .padding(Theme.Espace.paddingPuce)
                        .background(Theme.Couleur.puce, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Fond.page.ignoresSafeArea())
    }

    /// Pas de `!` sur l'URL des réglages : une chaîne système qui changerait de
    /// forme ne doit pas faire planter l'app, elle doit ne rien faire.
    private func ouvrirReglages() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Puce de sélection

/// Copie fidèle de la puce du studio. Elle est privée à ce fichier plutôt que
/// partagée pour l'instant : dupliquer vingt lignes de mise en forme coûte moins
/// cher qu'un composant commun mal factorisé, et le jour où un fichier
/// `Composants.swift` existera, les deux se remplaceront d'un seul geste.
///
/// Le fond actif reste l'orange de la marque et non l'accent de l'objectif : les
/// neuf accents sont des pastels très clairs sur lesquels le texte sombre
/// perdrait tout contraste. L'accent est rappelé par la gommette, où il ne porte
/// aucune lisibilité.
private struct PuceObjectifViseur: View {

    let lens: Lens
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: lens.accent))
                .frame(width: 6, height: 6)
                // Masquée et non retirée : un retrait conditionnel changerait la
                // largeur de la puce au moment même où elle devient active, et
                // toute la rangée sursauterait.
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

/// Jumeau du curseur du studio, sans la pastille de pourcentage : sur un viseur
/// plein cadre, chaque point pris au bas de l'écran est du cadrage en moins. La
/// valeur reste annoncée à VoiceOver.
private struct CurseurIntensiteViseur: View {

    @Binding var valeur: Double
    @Environment(\.accentObjectif) private var accent

    var body: some View {
        GeometryReader { geo in
            let pouce = Theme.Espace.diametrePouceCurseur
            // La course utile exclut le diamètre du pouce, sinon le pouce
            // déborderait du cadre aux deux extrémités et 100 % ne coïnciderait
            // pas avec le bout du rail.
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
            // Toute la bande est saisissable, pas seulement le pouce : viser un
            // disque de 30 pt au doigt est un exercice, viser la ligne ne l'est
            // pas.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { geste in
                        let brut = (geste.location.x - pouce / 2) / course
                        valeur = min(max(Double(brut), 0), 1)
                    }
            )
        }
        .frame(height: Theme.Espace.diametrePouceCurseur)
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
