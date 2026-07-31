import SwiftUI

// Fiche détaillée d'un objectif.
//
// Le site consacre à chaque objectif un récit, une fiche technique, trois
// anecdotes et cinq à sept barres de caractéristique : c'est cette densité qui
// lui donne son crédit documentaire. Une fiche qui se contenterait du nom et
// d'une photo ramènerait l'app à un sélecteur de filtres, exactement ce que
// l'utilisateur reprochait à la version précédente.
//
// Toutes les constantes viennent de `Theme`. Aucune valeur littérale de
// typographie ni d'espacement ne doit apparaître ici : la version précédente a
// dérivé du site écran par écran précisément parce que chaque vue réinventait
// ses marges.

/// Fiche détaillée : bandeau de scène animée, récit, fiche technique,
/// anecdotes, signature optique.
struct LensDetailView: View {

    let lens: Lens

    /// Hauteur du bandeau de tête. Fixe et non proportionnelle à l'écran : la
    /// scène de bokeh est un rendu Metal continu, et une hauteur qui suivrait la
    /// rotation ou le clavier forcerait un redimensionnement de drawable à
    /// chaque changement — coûteux et visuellement instable.
    ///
    /// `static` et non stockée : une propriété d'instance privée risque de faire
    /// tomber l'initialiseur mémberwise en visibilité fichier, et les autres
    /// vues ne pourraient plus écrire `LensDetailView(lens:)`.
    private static let hauteurBandeau: CGFloat = 260

    /// L'accent est recalculé ici plutôt que lu dans l'environnement : c'est
    /// cette vue qui le POSE pour ses filles (la cascade `--accent` du site part
    /// de la carte). Le lire ici renverrait l'orange par défaut.
    private var accent: Color {
        Color(hex: lens.accent)
    }

    var body: some View {
        GeometryReader { geo in
            // Largeur de contenu calculée une seule fois et transmise vers le
            // bas. Les lignes de la fiche technique ont besoin d'une largeur de
            // colonne exacte (42 % du site) : un `GeometryReader` local à chaque
            // ligne rendrait une hauteur nulle et ferait s'effondrer la pile.
            let largeurUtile = min(geo.size.width, Theme.Espace.largeurMax)
                - Theme.Espace.margeSection * 2

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {

                    bandeau

                    entete

                    recit

                    section(titre: "Caractéristiques techniques") {
                        ficheTechnique(largeurUtile: largeurUtile)
                    }

                    section(titre: "Le saviez-vous") {
                        anecdotes
                    }

                    section(titre: "La signature optique") {
                        signatureOptique
                    }
                }
                .frame(maxWidth: Theme.Espace.largeurMax)
                .padding(.horizontal, Theme.Espace.margeSection)
                // Respiration finale : sans elle, la dernière barre colle à la
                // barre d'onglets, qui est opaque et noire comme le fond.
                .padding(.bottom, Theme.Espace.paddingGrille.bottom)
                .frame(maxWidth: .infinity)
            }
            // Le dégradé est ancré au cadre visible, pas au contenu défilant :
            // ancré au contenu, son halo haut disparaîtrait dès le premier
            // geste et le fond virerait au noir plat au milieu de la lecture.
            .background(Theme.Fond.page)
            // Le site force le noir pur hors contenu (encoche, barre d'accueil,
            // rebond de défilement) ; le dégradé, lui, reste dans le cadre.
            .background(Theme.Couleur.fond.ignoresSafeArea())
        }
        // Posée une fois pour toute la hiérarchie : les barres, les puces
        // d'anecdote et la signature la lisent sans qu'on la fasse descendre en
        // paramètre à travers quatre niveaux de vues.
        .environment(\.accentObjectif, accent)
        .navigationTitle(lens.name)
        .navigationBarTitleDisplayMode(.inline)
        // Sans ces trois modificateurs, la barre de navigation reste dans
        // l'apparence du système : en apparence claire elle poserait un titre
        // sombre sur un matériau clair au-dessus d'une page noire, et la
        // rupture serait la première chose que l'œil verrait.
        .toolbarBackground(Theme.Couleur.fond, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Bandeau de scène

    /// Scène de bokeh animée, avec le numéro du catalogue et le bloc titre —
    /// exactement le chrome des cartes du site.
    private var bandeau: some View {
        ZStack(alignment: .bottomLeading) {

            BokehCanevas(lens: lens)
                // Le rendu Metal ne dit rien à VoiceOver ; le nom et la focale
                // sont juste en dessous, les annoncer deux fois serait du bruit.
                .accessibilityHidden(true)

            // Le titre et le numéro restent des vues SwiftUI posées PAR-DESSUS
            // la scène : les faire entrer dans le rendu Metal leur appliquerait
            // le grain et la vignette, et le texte deviendrait sale.
            VStack(alignment: .leading, spacing: 2) {
                Text(lens.name)
                    .font(Theme.Police.nomObjectif)
                    .tracking(Theme.Tracking.nomObjectif)
                    .foregroundStyle(Theme.Couleur.texte)

                Text(lens.focal)
                    .font(Theme.Police.focale)
                    .foregroundStyle(accent)
            }
            .shadow(
                color: Theme.Ombre.couleurTitreSurScene,
                radius: Theme.Ombre.rayonTitreSurScene,
                x: 0,
                y: Theme.Ombre.decalageTitreSurScene
            )
            .padding(.leading, Theme.Espace.margeTitreSurScene)
            .padding(.trailing, Theme.Espace.margeTitreSurScene)
            .padding(.bottom, Theme.Espace.margeBasTitreSurScene)
        }
        .frame(height: Self.hauteurBandeau)
        .frame(maxWidth: .infinity)
        // Rognage AVANT la bordure : la MTKView est un calque UIKit qui déborde
        // sans complexe des coins arrondis si on se contente d'un `overlay`.
        .clipShape(RoundedRectangle(cornerRadius: Theme.Rayon.scene, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Text(lens.indexLabel)
                .font(Theme.Police.numeroCarte)
                .tracking(Theme.Tracking.numeroCarte)
                .foregroundStyle(Theme.Couleur.numeroCarte)
                .padding(.top, Theme.Espace.margeHautNumeroCarte)
                .padding(.trailing, Theme.Espace.margeDroiteNumeroCarte)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Rayon.scene, style: .continuous)
                .strokeBorder(Theme.Couleur.bordure, lineWidth: Theme.Espace.epaisseurBordure)
        )
        .padding(.top, Theme.Espace.paddingGrille.top)
    }

    // MARK: - En-tête textuel

    /// Origine, époque et phrase de signature. La signature porte déjà ses
    /// guillemets français dans la donnée du catalogue : ne rien ajouter ici.
    private var entete: some View {
        VStack(alignment: .leading, spacing: Theme.Espace.ecartTraits) {
            Text("\(lens.origin) · \(lens.era)".uppercased())
                .font(Theme.Police.meta)
                .tracking(Theme.Tracking.meta)
                .foregroundStyle(Theme.Couleur.texteAttenue)
                .fixedSize(horizontal: false, vertical: true)

            Text(lens.signature)
                .font(Theme.Police.signatureCarte)
                .foregroundStyle(accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Espace.paddingCorpsCarte.top)
    }

    // MARK: - Récit

    private var recit: some View {
        Text(lens.story)
            .font(Theme.Police.recit)
            // `lineSpacing` AJOUTE de l'espace au-delà de la hauteur de ligne
            // par défaut : la valeur du thème est déjà la différence avec le
            // `line-height` 1.55 du site, il ne faut surtout pas la recalculer.
            .lineSpacing(Theme.Interligne.recit)
            .foregroundStyle(Theme.Couleur.texteSecondaire)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Espace.margeHautFiche)
    }

    // MARK: - Fiche technique

    private func ficheTechnique(largeurUtile: CGFloat) -> some View {
        // Le terme occupe 42 % de la largeur INTÉRIEURE de la carte : on retire
        // donc les deux marges de la carte avant d'appliquer la proportion,
        // sinon les valeurs longues (« plusieurs millions d'exemplaires »)
        // repoussent la colonne et le tableau perd son alignement.
        let largeurInterieure = largeurUtile
            - Theme.Espace.paddingCorpsCarte.leading
            - Theme.Espace.paddingCorpsCarte.trailing
        let largeurTerme = max(90, largeurInterieure * Theme.Espace.fractionTermeSpec)

        return carte {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lens.specs.enumerated()), id: \.element.id) { index, spec in
                    // Filet seulement ENTRE les lignes : un séparateur après la
                    // dernière ligne dessinerait un trait orphelin juste
                    // au-dessus du bord de la carte.
                    if index > 0 {
                        Rectangle()
                            .fill(Theme.Couleur.rail)
                            .frame(height: Theme.Espace.epaisseurBordure)
                            .padding(.vertical, Theme.Espace.ecartLignesSpecs)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: Theme.Espace.ecartColonnesSpecs) {
                        Text(spec.label)
                            .font(Theme.Police.specTerme)
                            .foregroundStyle(Theme.Couleur.texteAttenue)
                            .frame(width: largeurTerme, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(spec.value)
                            .font(Theme.Police.specValeur)
                            .foregroundStyle(Theme.Couleur.texteSecondaire)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Les deux colonnes forment une seule information : lues
                    // séparément, VoiceOver annoncerait « Poids » puis, plus
                    // tard, « ≈ 230 g » sans lien entre les deux.
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Anecdotes

    private var anecdotes: some View {
        carte {
            VStack(alignment: .leading, spacing: Theme.Espace.ecartAnecdotes) {
                ForEach(lens.facts, id: \.self) { fait in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        // Puce dessinée à la main, en accent : `Text` ne sait pas
                        // teinter le marqueur d'une liste, et le retrait du site
                        // (18 pt) ne se reproduit pas avec un caractère « • »
                        // suivi d'une espace, dont la largeur varie avec la police.
                        Text("•")
                            .font(Theme.Police.anecdote)
                            .foregroundStyle(accent)
                            .frame(width: Theme.Espace.retraitAnecdotes, alignment: .leading)

                        Text(fait)
                            .font(Theme.Police.anecdote)
                            .lineSpacing(Theme.Interligne.anecdote)
                            .foregroundStyle(Theme.Couleur.texteSecondaire)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Sans cela VoiceOver lit « puce » avant chaque anecdote.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(fait))
                }
            }
        }
    }

    // MARK: - Signature optique

    private var signatureOptique: some View {
        VStack(alignment: .leading, spacing: Theme.Espace.ecartTraits) {
            ForEach(Array(lens.traits.enumerated()), id: \.element.id) { index, trait in
                // Décalage croissant : les barres se remplissent en cascade au
                // lieu de sauter d'un bloc. Le pas reste court (5 centièmes) —
                // au-delà, la dernière barre d'une liste de sept arriverait
                // après que l'œil a déjà quitté la section.
                TraitBar(trait: trait, delai: Double(index) * 0.05)
            }
        }
    }

    // MARK: - Fabriques communes

    /// Titre de section en majuscules espacées, suivi de son contenu.
    /// Rendu générique parce qu'un `some View` en paramètre imposerait de
    /// construire la vue avant l'appel, et on perdrait la syntaxe à accolades.
    private func section<Contenu: View>(
        titre: String,
        @ViewBuilder contenu: () -> Contenu
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Espace.ecartTraits) {
            Text(titre.uppercased())
                .font(Theme.Police.meta)
                .tracking(Theme.Tracking.meta)
                .foregroundStyle(Theme.Couleur.texteAttenue)
                // Titre de section : `.isHeader` permet la navigation par
                // en-têtes dans le rotor de VoiceOver, sur une page longue c'est
                // la différence entre parcourir et subir.
                .accessibilityAddTraits(.isHeader)

            contenu()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Espace.paddingSectionFin.top)
    }

    /// Panneau sombre à coins arrondis, identique à la carte du catalogue.
    private func carte<Contenu: View>(@ViewBuilder contenu: () -> Contenu) -> some View {
        contenu()
            .padding(Theme.Espace.paddingCorpsCarte)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Rayon.carte, style: .continuous)
                    .fill(Theme.Couleur.panneau)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Rayon.carte, style: .continuous)
                    .strokeBorder(Theme.Couleur.bordure, lineWidth: Theme.Espace.epaisseurBordure)
            )
    }
}

// MARK: - Barre de caractéristique

/// Une caractéristique d'objectif : libellé à gauche, barre remplie à droite.
///
/// Le site pose deux colonnes égales (`1fr 1fr`) : la barre occupe donc la
/// moitié de la largeur, et les valeurs de deux objectifs différents restent
/// comparables d'une fiche à l'autre. Une barre pleine largeur serait plus
/// spectaculaire mais rendrait la comparaison impossible, seul intérêt réel de
/// ces données.
struct TraitBar: View {

    let trait: Trait

    /// Retard d'entrée, pour l'effet de cascade dans une liste.
    var delai: Double = 0

    /// Lue dans l'environnement, comme la cascade `--accent` du site : la barre
    /// se teinte de l'objectif courant sans que l'appelant y pense.
    @Environment(\.accentObjectif) private var accent

    /// Respecter « Réduire les animations » n'est pas un raffinement : une barre
    /// qui glisse à chaque apparition de section est exactement le mouvement que
    /// ce réglage existe pour supprimer.
    @Environment(\.accessibilityReduceMotion) private var mouvementReduit

    @State private var deploye = false

    /// Fraction effectivement peinte. Bornée : une donnée hors de [0, 1]
    /// déborderait du rail, et un remplissage négatif ferait un `frame` de
    /// largeur négative — que SwiftUI traite en assertion à l'exécution.
    private var fraction: CGFloat {
        guard deploye else { return 0 }
        return CGFloat(min(max(trait.value, 0), 1))
    }

    var body: some View {
        HStack(spacing: Theme.Espace.ecartColonnesTraits) {
            Text(trait.label)
                .font(Theme.Police.labelTrait)
                .foregroundStyle(Theme.Couleur.texteAttenue)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Couleur.rail)

                    Capsule()
                        .fill(Theme.Fond.degradeTrait(accent: accent))
                        .frame(width: geo.size.width * fraction)
                }
            }
            // Le `GeometryReader` prend toute la place qu'on lui laisse : sans
            // cette hauteur imposée, il mangerait la verticale de la ligne et
            // les barres se retrouveraient à des dizaines de points d'écart.
            .frame(height: Theme.Espace.hauteurRailTrait)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            // Idempotent : SwiftUI peut rappeler `onAppear` au retour d'un
            // arrière-plan ou d'une navigation, et rejouer l'animation ferait
            // clignoter toutes les barres d'une page déjà lue.
            guard !deploye else { return }
            if mouvementReduit {
                deploye = true
            } else {
                withAnimation(.easeOut(duration: 0.55).delay(delai)) {
                    deploye = true
                }
            }
        }
        // Le rail est décoratif ; ce qui compte pour VoiceOver, c'est le couple
        // libellé / intensité, annoncé en pourcentage plutôt qu'en « 0,85 ».
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(trait.label))
        .accessibilityValue(Text("\(Int((min(max(trait.value, 0), 1) * 100).rounded())) %"))
    }
}
