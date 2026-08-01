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

    /// Focale réglée à la main, en millimètres — `nil` tant que l'utilisateur
    /// n'y a pas touché.
    ///
    /// L'OPTIONNEL EST LE FOND DU SUJET, pas une commodité. Il y a deux
    /// commandes de zoom : le choix de l'objectif, qui pose sa focale de repos,
    /// et ce curseur. Si la valeur manuelle était un `Double` ordinaire, il
    /// faudrait décider à chaque changement d'objectif si elle prime ou non — et
    /// les deux réponses sont mauvaises : la garder fige le cadrage d'un
    /// Trioplan sur celui d'un Summicron, l'écraser interdit de comparer deux
    /// verres au même cadrage. `nil` dit « je suis l'objectif », une valeur dit
    /// « je suis réglé », et le changement d'objectif ne fait que revenir au
    /// premier état.
    @State private var focaleManuelle: Double?

    /// Vrai tant que l'onglet est à l'écran. Sans ce drapeau, un retour au
    /// premier plan relancerait la session même si l'utilisateur est entre-temps
    /// passé sur un autre onglet — la caméra chaufferait pour personne.
    @State private var ongletVisible = false

    /// Jeton de la temporisation qui efface la confirmation de capture. Il évite
    /// qu'une ancienne temporisation efface un message plus récent : deux
    /// captures rapprochées feraient sinon disparaître la seconde au bout d'une
    /// demi-seconde.
    @State private var jetonRetour = UUID()

    /// Panneau des outils replié par défaut : ces réglages se posent une
    /// fois puis s'oublient, et les laisser à l'écran mangerait le cadrage.
    @State private var outilsOuverts = false

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
            // Le zoom suit la focale de l'objectif : un Trioplan 100 mm cadre
            // presque quatre fois plus serré qu'un 26 mm de téléphone.
            camera.appliquerZoom(pour: objectif)
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
            // Changer d'objectif ANNULE le réglage manuel : voir `focaleManuelle`.
            focaleManuelle = nil
            camera.appliquerZoom(pour: nouvel)
        }
        .onChange(of: focaleManuelle) { _, nouvelle in
            guard let nouvelle else { return }
            camera.appliquerFocale(nouvelle)
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
            // DÉCLENCHEUR MATÉRIEL — boutons de volume et bouton Commande.
            //
            // Posé sur le viseur, qui est la seule vue présente pendant toute
            // la durée de vie de l'écran : l'accrocher à une commande du bas le
            // ferait disparaître avec elle. La vue superposée est transparente
            // et ne capte aucun toucher.
            //
            // Un appui pendant un enregistrement l'ARRÊTE, il ne prend pas une
            // photo : c'est le geste attendu, et prendre une photo à ce moment
            // laisserait la vidéo tourner sans que rien ne le signale.
            .overlay(
                DeclencheurPhysique {
                    if camera.enregistrementEnCours {
                        camera.basculerEnregistrement()
                    } else {
                        camera.declencher()
                    }
                }
                .allowsHitTesting(false)
            )
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

            // Posé sous la barre haute et aligné à droite : c'est le seul coin
            // du viseur qu'aucune commande n'occupe, et il faut pouvoir cadrer
            // sans que l'histogramme recouvre le sujet.
            if camera.outils.histogramme, !camera.histogramme.estVide {
                HStack {
                    Spacer(minLength: 0)
                    VueHistogramme(donnees: camera.histogramme)
                        .frame(width: 148, height: 62)
                }
                .padding(.horizontal, Theme.Espace.margeSection)
                .padding(.top, 8)
                .transition(.opacity)
            }

            if outilsOuverts {
                HStack {
                    Spacer(minLength: 0)
                    panneauOutils
                }
                .padding(.horizontal, Theme.Espace.margeSection)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

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

    /// Une aide est-elle armée ? Sert à teinter le bouton d'accès : un outil
    /// actif alors que le panneau est refermé doit rester signalé, sans quoi on
    /// se demande d'où viennent les hachures vertes à l'écran.
    private var outilsActifs: Bool {
        camera.outils.zebras || camera.outils.peaking
            || camera.outils.grille || camera.outils.histogramme
            || camera.vueNeutre || camera.format != .natif
    }

    /// PANNEAU DES OUTILS PROFESSIONNELS.
    ///
    /// Repliable, et refermé par défaut : ces réglages se posent une fois puis
    /// s'oublient, et les laisser en permanence à l'écran mangerait le cadrage
    /// — or le viseur est ce qu'on est venu regarder.
    private var panneauOutils: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("OUTILS")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundColor(Theme.Couleur.texteAttenue)

            interrupteur("Vue neutre", "eye.slash",
                         actif: camera.vueNeutre) { camera.vueNeutre.toggle() }
            interrupteur("Focus peaking", "camera.filters",
                         actif: camera.outils.peaking) { camera.outils.peaking.toggle() }
            interrupteur("Zébras", "sun.max",
                         actif: camera.outils.zebras) { camera.outils.zebras.toggle() }
            interrupteur("Grille des tiers", "grid",
                         actif: camera.outils.grille) { camera.outils.grille.toggle() }
            interrupteur("Histogramme", "waveform",
                         actif: camera.outils.histogramme) { camera.outils.histogramme.toggle() }

            Divider().overlay(Theme.Couleur.texteAttenue.opacity(0.3))

            Text("FORMAT")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundColor(Theme.Couleur.texteAttenue)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FormatPhoto.allCases) { format in
                        Button {
                            camera.format = format
                        } label: {
                            Text(format.titre)
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(camera.format == format
                                            ? Theme.Couleur.orange
                                            : Color.white.opacity(0.12),
                                            in: Capsule())
                                .foregroundColor(camera.format == format
                                                 ? Theme.Couleur.texteSurAccent
                                                 : Theme.Couleur.texte)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .padding(16)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18,
                                                               style: .continuous))
    }

    private func interrupteur(_ titre: String,
                              _ symbole: String,
                              actif: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbole)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22)
                Text(titre)
                    .font(.system(size: 15, weight: .medium))
                Spacer(minLength: 8)
                // Pastille pleine ou vide plutôt qu'un `Toggle` : le style
                // système impose un vert qui jure avec l'orange de l'app, et se
                // redessine mal sur un fond translucide.
                Circle()
                    .fill(actif ? Theme.Couleur.orange : Color.white.opacity(0.18))
                    .frame(width: 18, height: 18)
            }
            .foregroundColor(actif ? Theme.Couleur.orange : Theme.Couleur.texte)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(actif ? [.isSelected] : [])
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

            // Zoom courant. Il n'est pas décoratif : c'est la seule façon de
            // savoir que changer d'objectif a bien changé le CADRAGE, et pas
            // seulement le rendu.
            Text(String(format: "×%.1f", camera.zoom))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.Couleur.texte.opacity(0.75))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.45), in: Capsule())

            if camera.enregistrementEnCours {
                chronometre
                    .transition(.opacity)
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { outilsOuverts.toggle() }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(outilsOuverts || outilsActifs
                                     ? Theme.Couleur.orange : Theme.Couleur.texte)
                    .frame(width: 42, height: 42)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Outils professionnels")

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
            commandeFocale
            curseur
            noteRetour
            barreDeclencheurs
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

    /// SECONDE COMMANDE DE ZOOM : la focale, réglée à la main sur toute la plage.
    ///
    /// La première commande est le choix de l'objectif, qui pose sa focale de
    /// repos. Elle ne donne accès qu'à neuf valeurs, toutes comprises entre 35 et
    /// 100 mm : ni le 25 mm ni le 250 mm de l'Angénieux — pourtant écrits sur sa
    /// fiche — n'étaient atteignables, et les deux bouts de la plage n'existaient
    /// tout simplement pas dans l'app.
    ///
    /// La valeur affichée vient du CONTRÔLEUR (`camera.focale`) et non de l'état
    /// local : elle est donc bornée par ce que le périphérique a réellement posé.
    /// Un curseur qui afficherait sa propre position annoncerait 250 mm sur un
    /// modèle qui plafonne à 180 — exactement le viseur qui ment sur ce qu'on va
    /// obtenir.
    private var commandeFocale: some View {
        HStack(spacing: 12) {
            // Le libellé sert de bouton de retour à la focale de l'objectif.
            // Pas d'icône supplémentaire : la barre du viseur est déjà chargée,
            // et le geste se découvre en une fois.
            Button {
                focaleManuelle = nil
                camera.appliquerZoom(pour: objectif)
            } label: {
                Text("FOCALE")
                    .font(Theme.Police.meta)
                    .tracking(Theme.Tracking.meta)
                    .foregroundColor(focaleManuelle == nil
                                     ? Theme.Couleur.texteAttenue
                                     : Color(hex: objectif.accent))
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Revenir à la focale de l'objectif")

            CurseurFocaleViseur(focale: $focaleManuelle,
                                repos: objectif.focaleMM,
                                plage: camera.plageFocale)

            Text("\(Int(camera.focale.rounded())) mm")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.Couleur.texte)
                .frame(width: 52, alignment: .trailing)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Espace.margeSection)
        .padding(.top, 10)
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

    /// Barre du bas : bouton vidéo à gauche, déclencheur au centre.
    ///
    /// La vidéo a son PROPRE bouton plutôt qu'un sélecteur de mode. Un mode
    /// impose de savoir dans lequel on se trouve avant d'agir ; deux boutons se
    /// lisent d'un coup d'œil, et rien n'interdit de filmer puis de
    /// photographier dans la seconde.
    private var barreDeclencheurs: some View {
        ZStack {
            declencheur

            HStack {
                boutonVideo
                    .padding(.leading, 34)
                Spacer()
            }
        }
    }

    private var boutonVideo: some View {
        Button {
            camera.basculerEnregistrement()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Theme.Couleur.texte.opacity(0.85), lineWidth: 3)
                    .frame(width: 54, height: 54)

                // Rond plein au repos, CARRÉ pendant l'enregistrement : la même
                // convention que toutes les apps de capture, immédiatement
                // comprise sans légende.
                RoundedRectangle(cornerRadius: camera.enregistrementEnCours ? 5 : 19,
                                 style: .continuous)
                    .fill(Color.red)
                    .frame(width: camera.enregistrementEnCours ? 24 : 38,
                           height: camera.enregistrementEnCours ? 24 : 38)
                    .animation(.easeInOut(duration: 0.18),
                               value: camera.enregistrementEnCours)
            }
        }
        .buttonStyle(.plain)
        .disabled(camera.etat != .enMarche || camera.captureEnCours)
        .opacity(camera.etat == .enMarche && !camera.captureEnCours ? 1 : 0.4)
        .accessibilityLabel(camera.enregistrementEnCours
                            ? "Arrêter l'enregistrement"
                            : "Filmer une vidéo")
    }

    /// Chronomètre, affiché uniquement pendant l'enregistrement.
    private var chronometre: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
            Text(Self.duree(camera.secondesEnregistrees))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.Couleur.texte)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
    }

    static func duree(_ secondes: Int) -> String {
        String(format: "%02d:%02d", secondes / 60, secondes % 60)
    }

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
/// Curseur de focale, gradué en millimètres, à course LOGARITHMIQUE.
///
/// L'échelle logarithmique n'est pas un raffinement : la focale se perçoit en
/// RAPPORTS, pas en écarts. Passer de 25 à 50 mm divise le champ par deux, passer
/// de 225 à 250 le réduit de 11 %. Sur une course linéaire de 25 à 250, la moitié
/// basse — celle où se joue tout le cadrage courant, 25 à 137 mm — tiendrait dans
/// la moitié du rail, et les neuf dixièmes de la course serviraient à départager
/// des téléobjectifs voisins. En logarithmique, chaque doublement de focale occupe
/// la même longueur : 25→50, 50→100, 100→200 sont trois segments égaux.
///
/// Le pouce se pose donc au tiers pour un 50 mm plutôt qu'au dixième.
private struct CurseurFocaleViseur: View {

    /// `nil` = la focale suit l'objectif. Le curseur se place alors sur `repos`
    /// mais n'écrit rien tant qu'on ne le touche pas.
    @Binding var focale: Double?

    /// Focale de repos de l'objectif courant, en millimètres.
    let repos: Double

    /// Bornes réellement atteignables par le périphérique.
    let plage: ClosedRange<Double>

    @Environment(\.accentObjectif) private var accent

    /// Repères gravés sur le rail. Les focales classiques du 24×36, celles qu'un
    /// photographe reconnaît sans les lire : grand-angle, normal, portrait,
    /// téléobjectifs. Celles qui tombent hors de la plage du périphérique sont
    /// simplement omises.
    private static let reperes: [Double] = [25, 35, 50, 85, 135, 200, 250]

    /// Position dans [0, 1] d'une focale sur la course logarithmique.
    private func fraction(_ mm: Double) -> CGFloat {
        let bas = plage.lowerBound
        let haut = plage.upperBound
        // Une plage dégénérée (périphérique à focale unique) donnerait un
        // logarithme nul au dénominateur : le pouce se pose alors à gauche et le
        // rail ne répond plus, ce qui est la traduction exacte de « rien à
        // régler ».
        guard haut > bas, bas > 0 else { return 0 }
        let position = log(min(max(mm, bas), haut) / bas) / log(haut / bas)
        return CGFloat(position)
    }

    /// L'inverse : la focale d'une position du pouce.
    ///
    /// Nommée `focalePour` et non `focale` : une méthode et une propriété
    /// stockée de même nom sont une redéclaration invalide en Swift, et le
    /// diagnostic ne pointe pas la ligne fautive.
    private func focalePour(_ fraction: CGFloat) -> Double {
        let bas = plage.lowerBound
        let haut = plage.upperBound
        guard haut > bas, bas > 0 else { return bas }
        let f = Double(min(max(fraction, 0), 1))
        return bas * pow(haut / bas, f)
    }

    var body: some View {
        GeometryReader { geo in
            let pouce = Theme.Espace.diametrePouceCurseur
            let course = max(geo.size.width - pouce, 1)
            let courante = focale ?? repos
            let centre = pouce / 2 + course * fraction(courante)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Couleur.rail)
                    .frame(height: Theme.Espace.hauteurRailCurseur)

                // Repères, sous le pouce et au-dessus du rail.
                ForEach(Self.reperes.filter { plage.contains($0) }, id: \.self) { mm in
                    Capsule()
                        .fill(Theme.Couleur.texte.opacity(0.38))
                        .frame(width: 1.5, height: Theme.Espace.hauteurRailCurseur * 2.2)
                        .offset(x: pouce / 2 + course * fraction(mm) - 0.75)
                }

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
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { geste in
                        let brut = (geste.location.x - pouce / 2) / course
                        focale = focalePour(brut)
                    }
            )
        }
        .frame(height: Theme.Espace.diametrePouceCurseur)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Focale")
        .accessibilityValue("\(Int((focale ?? repos).rounded())) millimètres")
        .accessibilityAdjustableAction { direction in
            // Pas d'incrément fixe en millimètres : un pas de 5 mm est énorme à
            // 25 et dérisoire à 250. Un pas MULTIPLICATIF de 6 % donne partout la
            // même variation de champ, soit une quarantaine de crans sur toute la
            // course.
            let courante = focale ?? repos
            switch direction {
            case .increment: focale = min(plage.upperBound, courante * 1.06)
            case .decrement: focale = max(plage.lowerBound, courante / 1.06)
            @unknown default: break
            }
        }
    }
}

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
