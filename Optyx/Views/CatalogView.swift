import Foundation
import SwiftUI

// Écran principal : le catalogue.
//
// C'est l'écran de la promesse. L'utilisateur a répété une douzaine de fois que
// les effets « ne se voient pas » dans l'app alors que le site lui plaît : la
// réponse n'est pas un réglage de plus, c'est que la scène de bokeh soit posée
// en grand, tout en haut, avant le moindre texte. Le héros n'est donc pas une
// illustration décorative — c'est la démonstration elle-même, rendue par le
// MÊME shader que celui qui traitera sa photo dans le studio.
//
// Aucune constante visuelle n'est écrite ici : tout vient de `Theme`. C'est
// exactement de cette façon que la version précédente avait dérivé du site,
// écran après écran, chaque vue réinventant sa propre marge.

/// Catalogue des neuf objectifs : héros animé, barre de sélection, cartes.
struct CatalogView: View {

    /// L'objectif du héros, retenu par son identifiant et non par sa valeur.
    ///
    /// `Lens` est `Hashable` mais son égalité passe par les UUID de `Spec` et
    /// `Trait` : deux copies du même objectif ne sont donc pas égales. Stocker
    /// une chaîne évite ce piège pour la comparaison « cette puce est-elle
    /// active ? », qui serait sinon fausse en permanence.
    @State private var objectifHero: String = Lens.catalog[0].id

    private var heros: Lens { Lens.lens(id: objectifHero) }

    var body: some View {
        NavigationStack {
            // Un seul `GeometryReader`, à la racine : le héros a besoin de la
            // hauteur d'écran et la grille de la largeur. En mettre un dans le
            // `ScrollView` donnerait une hauteur proposée de zéro et
            // écraserait le contenu.
            GeometryReader { geometrie in
                ZStack {
                    // Noir pur SOUS les zones sûres (encoche, barre d'accueil,
                    // rebond de défilement) et dégradé elliptique UNIQUEMENT
                    // sur le contenu : c'est la répartition du site, où le
                    // `body` est noir et seul le contenu porte le halo.
                    Theme.Couleur.fond.ignoresSafeArea()
                    Theme.Fond.page

                    ScrollView(.vertical, showsIndicators: false) {
                        contenu(
                            largeur: geometrie.size.width,
                            hauteur: geometrie.size.height
                        )
                    }
                }
            }
            // Le catalogue se présente à fond perdu : une barre de navigation
            // vide poserait un bandeau translucide juste au-dessus de la scène
            // et couperait le héros en deux. Masquer ici ne concerne que la
            // racine — la fiche poussée garde sa barre et son bouton retour.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Lens.self) { objectif in
                LensDetailView(lens: objectif)
            }
        }
    }

    // MARK: - Composition

    @ViewBuilder
    private func contenu(largeur: CGFloat, hauteur: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            marque

            heroSection(hauteur: hauteur)

            rangeeDePuces

            titreDeSection

            grilleDeCartes(largeur: largeur)

            PiedDePage()
        }
        // Le site plafonne son contenu à 1100 px et le centre. Sans ce
        // plafond, les lignes de récit s'étireraient sur toute la largeur d'un
        // iPad et deviendraient illisibles.
        .frame(maxWidth: Theme.Espace.largeurMax)
        .frame(maxWidth: .infinity)
    }

    /// Marque « OPTYX ». Le site l'écrit déjà en capitales dans le balisage ;
    /// on fait de même plutôt que d'employer `.textCase(.uppercase)`, dont
    /// l'effet dépend du conteneur et sauterait dans certains contextes.
    private var marque: some View {
        Text("OPTYX")
            .font(Theme.Police.marque)
            .tracking(Theme.Tracking.marque)
            .foregroundColor(Theme.Couleur.orange)
            .padding(.horizontal, Theme.Espace.margeSection)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Héros

    /// Scène de bokeh de l'objectif sélectionné, en pleine largeur.
    ///
    /// La hauteur est bornée en bas comme en haut : sur un iPhone SE, 40 % de
    /// l'écran ne suffisent pas à laisser respirer les disques, et sur un iPad
    /// une scène de 500 pt repousserait les cartes hors de vue au premier coup
    /// d'œil, ce qui est précisément ce qu'on veut éviter.
    private func heroSection(hauteur: CGFloat) -> some View {
        let hauteurScene = min(
            max(240, hauteur * 0.40),
            Theme.Espace.hauteurMaxSceneHero
        )
        let accent = Color(hex: heros.accent)

        return NavigationLink(value: heros) {
            ZStack {
                // Le cadre du site est peint sous la scène : si Metal est
                // indisponible, le repli reste un dégradé habité plutôt qu'un
                // rectangle noir mort.
                Theme.Fond.cadreScene

                BokehCanevas(lens: heros)
                    // La scène est décorative : le nom, la focale et la
                    // signature juste en dessous disent déjà tout à VoiceOver,
                    // et une MTKView n'a rien à annoncer.
                    .accessibilityHidden(true)
            }
            .frame(height: hauteurScene)
            .frame(maxWidth: .infinity)
            // Voile de lisibilité. Il part de la moitié de la scène, pas du
            // haut : plus tôt, il éteindrait les disques de bokeh du centre,
            // c'est-à-dire exactement ce qu'on est venu montrer.
            .overlay {
                LinearGradient(
                    stops: [
                        Gradient.Stop(color: .clear, location: 0),
                        Gradient.Stop(color: .black.opacity(0.15), location: 0.5),
                        Gradient.Stop(color: .black.opacity(0.88), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                Text(heros.indexLabel)
                    .font(Theme.Police.numeroCarte)
                    .tracking(Theme.Tracking.numeroCarte)
                    .foregroundColor(Theme.Couleur.numeroCarte)
                    .padding(.top, Theme.Espace.margeHautNumeroCarte)
                    .padding(.trailing, Theme.Espace.margeDroiteNumeroCarte)
            }
            .overlay(alignment: .bottomLeading) {
                legendeHero(accent: accent)
                    .padding(.horizontal, Theme.Espace.margeTitreSurScene)
                    .padding(.bottom, Theme.Espace.margeBasTitreSurScene)
                    // L'identité change avec l'objectif : c'est ce qui permet
                    // à SwiftUI de jouer un fondu croisé du texte pendant que
                    // le renderer fond sa palette. Sans `.id`, le texte
                    // changerait d'un coup au milieu d'une scène qui, elle,
                    // se transforme en douceur.
                    .id(heros.id)
                    .transition(.opacity)
            }
            // Rognage APRÈS les surcouches : sinon le voile et le titre
            // débordent des coins arrondis, défaut typique d'un `overflow`
            // oublié.
            .clipShape(RoundedRectangle(cornerRadius: Theme.Rayon.scene, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Rayon.scene, style: .continuous)
                    .strokeBorder(Theme.Couleur.bordure, lineWidth: Theme.Espace.epaisseurBordure)
            }
            .padding(.horizontal, Theme.Espace.margeSection)
        }
        // Sans `.plain`, le style de bouton par défaut teinterait le contenu
        // en bleu et ferait clignoter la scène entière au toucher.
        .buttonStyle(.plain)
    }

    private func legendeHero(accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(heros.name)
                    .font(Theme.Police.titreLegende)
                    .tracking(Theme.Tracking.titreLegende)
                    .foregroundColor(Theme.Couleur.texte)

                Text(heros.focal)
                    .font(Theme.Police.focale)
                    .foregroundColor(accent)
            }

            Text(heros.signature)
                .font(Theme.Police.signatureLegende)
                .foregroundColor(accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Une seule ombre pour tout le bloc : le texte se pose sur des points
        // lumineux mobiles, et une hampe blanche sur un disque clair devient
        // illisible sans elle.
        .shadow(
            color: Theme.Ombre.couleurTitreSurScene,
            radius: Theme.Ombre.rayonTitreSurScene,
            x: 0,
            y: Theme.Ombre.decalageTitreSurScene
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Barre de sélection

    private var rangeeDePuces: some View {
        ScrollViewReader { defilement in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Espace.ecartPuces) {
                    ForEach(Lens.catalog) { objectif in
                        Button {
                            // L'animation est portée par l'action, pas par un
                            // `.animation(value:)` sur la légende : le fondu
                            // du héros repose sur un changement d'identité,
                            // et seule une transaction explicite le fait jouer.
                            withAnimation(.easeInOut(duration: 0.32)) {
                                objectifHero = objectif.id
                            }
                        } label: {
                            PuceObjectif(lens: objectif, active: objectif.id == objectifHero)
                        }
                        .buttonStyle(.plain)
                        .id(objectif.id)
                    }
                }
                // Le padding est DANS la pile, pas sur le `ScrollView` : posé
                // à l'extérieur, il rognerait la zone de défilement et la
                // première puce se collerait au bord dès le premier geste.
                .padding(Theme.Espace.paddingRangeePuces)
            }
            .onChange(of: objectifHero) { _, nouvel in
                // La neuvième puce est hors écran sur un iPhone : sans ce
                // recentrage, choisir un objectif depuis une carte laisserait
                // la barre sur une puce inactive et la sélection paraîtrait
                // sans effet.
                withAnimation(.easeInOut(duration: 0.32)) {
                    defilement.scrollTo(nouvel, anchor: .center)
                }
            }
        }
        .accessibilityLabel("Choisir un objectif")
    }

    // MARK: Grille

    private var titreDeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Le catalogue")
                .font(Theme.Police.titreLegende)
                .tracking(Theme.Tracking.titreLegende)
                .foregroundColor(Theme.Couleur.texte)

            Text("NEUF VERRES · NEUF SIGNATURES")
                .font(Theme.Police.meta)
                .tracking(Theme.Tracking.meta)
                .foregroundColor(Theme.Couleur.texteAttenue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Espace.margeSection)
        .padding(.top, 18)
        .accessibilityAddTraits(.isHeader)
    }

    private func grilleDeCartes(largeur: CGFloat) -> some View {
        LazyVGrid(columns: colonnes(largeur: largeur), spacing: Theme.Espace.ecartCartes) {
            ForEach(Lens.catalog) { objectif in
                NavigationLink(value: objectif) {
                    CarteObjectif(lens: objectif, aLHonneur: objectif.id == objectifHero)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Espace.paddingGrille)
    }

    /// Une colonne sur iPhone, deux puis trois au-delà des ruptures du site.
    /// `GridItem(.adaptive:)` donnerait trois colonnes sur un iPhone Max en
    /// paysage — une mise en page que le site n'a jamais eue.
    private func colonnes(largeur: CGFloat) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Theme.Espace.ecartCartes),
            count: Theme.colonnes(largeur: largeur)
        )
    }
}

// MARK: - Puce de sélection

/// Pastille de la barre horizontale.
///
/// Le fond actif reste l'orange de la marque et NON l'accent de l'objectif :
/// les neuf accents sont des pastels très clairs, sur lesquels le texte sombre
/// du site perdrait tout contraste. L'accent est rappelé par la gommette, où
/// il ne porte aucune lisibilité.
private struct PuceObjectif: View {

    let lens: Lens
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: lens.accent))
                .frame(width: 6, height: 6)
                // Masquée plutôt que retirée : un retrait conditionnel
                // changerait la largeur de la puce au moment même où elle
                // devient active, et toute la rangée sursauterait.
                .opacity(active ? 0 : 1)

            Text(lens.name)
                .font(Theme.Police.puce)
                .foregroundColor(active ? Theme.Couleur.texteSurAccent : Theme.Couleur.textePuce)
                .lineLimit(1)
        }
        .padding(Theme.Espace.paddingPuce)
        .background(active ? Theme.Couleur.orange : Theme.Couleur.puce, in: Capsule())
        // Le trait de bouton vient déjà du `Button` parent ; on n'ajoute que la
        // sélection, sans quoi VoiceOver annonce neuf puces indiscernables.
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Carte d'objectif

/// Carte de la grille : identité de l'objectif, sans scène animée.
///
/// Volontairement PAS de `BokehCanevas` ici. Neuf MTKView à 60 Hz simultanées
/// videraient la batterie et feraient tomber le héros — celui qu'on est venu
/// regarder — sous les 30 images par seconde. La couleur de l'objectif est
/// portée par son accent : gommette, focale, signature et halo de fond.
private struct CarteObjectif: View {

    let lens: Lens
    /// Vrai lorsque cette carte est l'objectif actuellement au héros.
    let aLHonneur: Bool

    var body: some View {
        let accent = Color(hex: lens.accent)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(lens.indexLabel)
                    .font(Theme.Police.numeroCarte)
                    .tracking(Theme.Tracking.numeroCarte)
                    .foregroundColor(Theme.Couleur.numeroCarte)

                Spacer(minLength: 0)

                Circle()
                    .fill(accent)
                    .frame(width: 9, height: 9)
                    // Le halo tient lieu de reflet de verre : sur le panneau
                    // #131313, une pastille pleine sans diffusion a l'air
                    // d'un point de sélection, pas d'une lentille.
                    .shadow(color: accent.opacity(0.55), radius: 6, x: 0, y: 0)
            }
            .padding(.bottom, 12)

            Text(lens.name)
                .font(Theme.Police.nomObjectif)
                .tracking(Theme.Tracking.nomObjectif)
                .foregroundColor(Theme.Couleur.texte)
                .fixedSize(horizontal: false, vertical: true)

            Text(lens.focal)
                .font(Theme.Police.focale)
                .foregroundColor(accent)
                .padding(.top, 3)

            Text("\(lens.origin) · \(lens.era)".uppercased())
                .font(Theme.Police.meta)
                .tracking(Theme.Tracking.meta)
                .foregroundColor(Theme.Couleur.texteAttenue)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Text(lens.signature)
                .font(Theme.Police.signatureCarte)
                .foregroundColor(accent)
                // Les signatures tiennent sur deux lignes chez l'Angénieux :
                // sans `fixedSize`, la grille à deux colonnes tronque la
                // seconde ligne au lieu d'agrandir la carte.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            HStack(spacing: 6) {
                Text("Découvrir")
                    .font(Theme.Police.meta)
                    .tracking(Theme.Tracking.meta)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(Theme.Couleur.texteAttenue)
            .padding(.top, 14)
        }
        .padding(Theme.Espace.paddingCorpsCarte)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Rayon.carte, style: .continuous)
                .fill(Theme.Couleur.panneau)
                // Lueur d'accent dans l'angle supérieur gauche : c'est elle
                // qui distingue neuf cartes autrement identiques. L'opacité
                // reste basse — au-delà, le récit passerait sur un fond teinté
                // et le texte secondaire perdrait son contraste.
                .overlay {
                    EllipticalGradient(
                        colors: [accent.opacity(aLHonneur ? 0.17 : 0.075), .clear],
                        center: UnitPoint(x: 0.08, y: 0),
                        startRadiusFraction: 0,
                        endRadiusFraction: 0.8
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Rayon.carte, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Rayon.carte, style: .continuous)
                .strokeBorder(
                    aLHonneur ? accent.opacity(0.55) : Theme.Couleur.bordure,
                    lineWidth: Theme.Espace.epaisseurBordure
                )
        }
        // La carte entière est un seul élément pour VoiceOver : lue morceau
        // par morceau, la fiche devient six arrêts pour une seule destination.
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pied de page

private struct PiedDePage: View {

    var body: some View {
        VStack(spacing: Theme.Espace.ecartLignesPied) {
            (
                Text("Conçu et développé par ")
                    .foregroundColor(Theme.Couleur.texte)
                    + Text("Maxime Nathan Lestage")
                    .bold()
                    .foregroundColor(Theme.Couleur.orange)
            )
            .font(Theme.Police.credit)
            .multilineTextAlignment(.center)

            Text("© 2026 Optyx — Objectifs vintage simulés.")
                .font(Theme.Police.copyright)
                .foregroundColor(Theme.Couleur.texteDiscret)

            if !Self.version.isEmpty {
                Text(Self.version)
                    .font(Theme.Police.copyright)
                    .foregroundColor(Theme.Couleur.texteDiscret)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Espace.paddingPied)
    }

    /// Version lue dans le bundle, jamais écrite en dur.
    ///
    /// Les deux clés sont optionnelles et lues défensivement : un `Info.plist`
    /// mal généré ne doit pas faire planter le catalogue pour une ligne de
    /// pied de page. Quand rien n'est lisible, on n'affiche simplement rien —
    /// « Version ? » ne rendrait service à personne.
    private static var version: String {
        let infos = Bundle.main.infoDictionary
        let court = infos?["CFBundleShortVersionString"] as? String
        let compilation = infos?["CFBundleVersion"] as? String

        switch (court, compilation) {
        case let (.some(numero), .some(build)):
            return "Version \(numero) (\(build))"
        case let (.some(numero), .none):
            return "Version \(numero)"
        case let (.none, .some(build)):
            return "Compilation \(build)"
        case (.none, .none):
            return ""
        }
    }
}
