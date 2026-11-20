///
/// Generated file. Do not edit.
///
// coverage:ignore-file
// ignore_for_file: type=lint, unused_import
// dart format off

part of 'strings.g.dart';

// Path: <root>
typedef TranslationsEn = Translations; // ignore: unused_element
class Translations with BaseTranslations<AppLocale, Translations> {
	/// Returns the current translations of the given [context].
	///
	/// Usage:
	/// final t = Translations.of(context);
	static Translations of(BuildContext context) => InheritedLocaleData.of<AppLocale, Translations>(context).translations;

	/// You can call this constructor and build your own translation instance of this locale.
	/// Constructing via the enum [AppLocale.build] is preferred.
	Translations({Map<String, Node>? overrides, PluralResolver? cardinalResolver, PluralResolver? ordinalResolver, TranslationMetadata<AppLocale, Translations>? meta})
		: assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
		  _meta = meta ?? TranslationMetadata(
		    locale: AppLocale.en,
		    overrides: overrides ?? {},
		    cardinalResolver: cardinalResolver,
		    ordinalResolver: ordinalResolver,
		  ) {
		_meta.setFlatMapFunction(_flatMapFunction);
	}

	/// Metadata for the translations of <en>.
	final TranslationMetadata<AppLocale, Translations> _meta;
	@override TranslationMetadata<AppLocale, Translations> get $meta => _meta;

	/// Access flat map
	dynamic operator[](String key) => _meta.getTranslation(key);

	late final Translations _root = this; // ignore: unused_field

	Translations $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) => Translations(meta: meta ?? this.$meta);

	// Translations
	late final Translations$app$en app = Translations$app$en._(_root);
	late final Translations$nav$en nav = Translations$nav$en._(_root);
	late final Translations$setup$en setup = Translations$setup$en._(_root);
	late final Translations$create$en create = Translations$create$en._(_root);
	late final Translations$cover$en cover = Translations$cover$en._(_root);
	late final Translations$library$en library = Translations$library$en._(_root);
}

// Path: app
class Translations$app$en {
	Translations$app$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'YuE2 Studio'
	String get title => 'YuE2 Studio';

	/// en: 'Unofficial client. Not affiliated with the YuE2 authors.'
	String get unofficial => 'Unofficial client. Not affiliated with the YuE2 authors.';
}

// Path: nav
class Translations$nav$en {
	Translations$nav$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Create'
	String get create => 'Create';

	/// en: 'Cover'
	String get cover => 'Cover';

	/// en: 'Library'
	String get library => 'Library';
}

// Path: setup
class Translations$setup$en {
	Translations$setup$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Set up YuE2 Studio'
	String get title => 'Set up YuE2 Studio';

	/// en: 'The engine and the models are downloaded once into a private folder. Nothing outside it is touched.'
	String get intro => 'The engine and the models are downloaded once into a private folder. Nothing outside it is touched.';

	/// en: 'Install'
	String get install => 'Install';

	/// en: 'Resume'
	String get resume => 'Resume';

	/// en: 'Retry'
	String get retry => 'Retry';

	/// en: 'Installing...'
	String get installing => 'Installing...';

	/// en: 'All set'
	String get done => 'All set';

	/// en: 'Model weights are licensed CC BY-NC 4.0 and used with the permission of their creators. Non-commercial use only.'
	String get licence => 'Model weights are licensed CC BY-NC 4.0 and used with the permission of their creators. Non-commercial use only.';

	/// en: 'Needs about $size of free disk space.'
	String disk({required Object size}) => 'Needs about ${size} of free disk space.';

	/// en: 'Not enough free disk space: $need needed, $free available.'
	String noDisk({required Object need, required Object free}) => 'Not enough free disk space: ${need} needed, ${free} available.';

	/// en: 'Step failed: $message'
	String failed({required Object message}) => 'Step failed: ${message}';

	late final Translations$setup$step$en step = Translations$setup$step$en._(_root);
}

// Path: create
class Translations$create$en {
	Translations$create$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Create'
	String get title => 'Create';

	/// en: 'Style'
	String get style => 'Style';

	/// en: 'English, warm piano pop, expressive female voice, 88 BPM'
	String get styleHint => 'English, warm piano pop, expressive female voice, 88 BPM';

	/// en: 'Lyrics'
	String get lyrics => 'Lyrics';

	/// en: '[Verse]\nWrite your lyrics here\n\n[Chorus]\n...'
	String get lyricsHint => '[Verse]\nWrite your lyrics here\n\n[Chorus]\n...';

	/// en: 'Symbolic plan'
	String get plan => 'Symbolic plan';

	/// en: 'Full'
	String get planFull => 'Full';

	/// en: 'Melody'
	String get planMelody => 'Melody';

	/// en: 'Off'
	String get planOff => 'Off';

	/// en: 'Seed'
	String get seed => 'Seed';

	/// en: 'Random'
	String get seedHint => 'Random';

	/// en: 'Generate'
	String get generate => 'Generate';

	/// en: 'Added to the library'
	String get queued => 'Added to the library';

	/// en: 'Untitled'
	String get untitled => 'Untitled';
}

// Path: cover
class Translations$cover$en {
	Translations$cover$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Cover'
	String get title => 'Cover';

	/// en: 'Cover is coming soon.'
	String get soon => 'Cover is coming soon.';
}

// Path: library
class Translations$library$en {
	Translations$library$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Library'
	String get title => 'Library';

	/// en: 'No songs yet. Create one.'
	String get empty => 'No songs yet. Create one.';

	late final Translations$library$status$en status = Translations$library$status$en._(_root);
	late final Translations$library$stage$en stage = Translations$library$stage$en._(_root);
}

// Path: setup.step
class Translations$setup$step$en {
	Translations$setup$step$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Waiting'
	String get pending => 'Waiting';

	/// en: 'Working'
	String get running => 'Working';

	/// en: 'Done'
	String get done => 'Done';

	/// en: 'Failed'
	String get failed => 'Failed';
}

// Path: library.status
class Translations$library$status$en {
	Translations$library$status$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Queued'
	String get queued => 'Queued';

	/// en: 'Generating'
	String get generating => 'Generating';

	/// en: 'Done'
	String get done => 'Done';

	/// en: 'Failed'
	String get failed => 'Failed';
}

// Path: library.stage
class Translations$library$stage$en {
	Translations$library$stage$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Loading model'
	String get load => 'Loading model';

	/// en: 'Planning'
	String get abc => 'Planning';

	/// en: 'Composing'
	String get semantic => 'Composing';

	/// en: 'Rendering'
	String get nar => 'Rendering';

	/// en: 'Decoding'
	String get vae => 'Decoding';

	/// en: 'Transcribing'
	String get transcribe => 'Transcribing';
}

/// The flat map containing all translations for locale <en>.
/// Only for edge cases! For simple maps, use the map function of this library.
///
/// The Dart AOT compiler has issues with very large switch statements,
/// so the map is split into smaller functions (512 entries each).
extension on Translations {
	dynamic _flatMapFunction(String path) {
		return switch (path) {
			'app.title' => 'YuE2 Studio',
			'app.unofficial' => 'Unofficial client. Not affiliated with the YuE2 authors.',
			'nav.create' => 'Create',
			'nav.cover' => 'Cover',
			'nav.library' => 'Library',
			'setup.title' => 'Set up YuE2 Studio',
			'setup.intro' => 'The engine and the models are downloaded once into a private folder. Nothing outside it is touched.',
			'setup.install' => 'Install',
			'setup.resume' => 'Resume',
			'setup.retry' => 'Retry',
			'setup.installing' => 'Installing...',
			'setup.done' => 'All set',
			'setup.licence' => 'Model weights are licensed CC BY-NC 4.0 and used with the permission of their creators. Non-commercial use only.',
			'setup.disk' => ({required Object size}) => 'Needs about ${size} of free disk space.',
			'setup.noDisk' => ({required Object need, required Object free}) => 'Not enough free disk space: ${need} needed, ${free} available.',
			'setup.failed' => ({required Object message}) => 'Step failed: ${message}',
			'setup.step.pending' => 'Waiting',
			'setup.step.running' => 'Working',
			'setup.step.done' => 'Done',
			'setup.step.failed' => 'Failed',
			'create.title' => 'Create',
			'create.style' => 'Style',
			'create.styleHint' => 'English, warm piano pop, expressive female voice, 88 BPM',
			'create.lyrics' => 'Lyrics',
			'create.lyricsHint' => '[Verse]\nWrite your lyrics here\n\n[Chorus]\n...',
			'create.plan' => 'Symbolic plan',
			'create.planFull' => 'Full',
			'create.planMelody' => 'Melody',
			'create.planOff' => 'Off',
			'create.seed' => 'Seed',
			'create.seedHint' => 'Random',
			'create.generate' => 'Generate',
			'create.queued' => 'Added to the library',
			'create.untitled' => 'Untitled',
			'cover.title' => 'Cover',
			'cover.soon' => 'Cover is coming soon.',
			'library.title' => 'Library',
			'library.empty' => 'No songs yet. Create one.',
			'library.status.queued' => 'Queued',
			'library.status.generating' => 'Generating',
			'library.status.done' => 'Done',
			'library.status.failed' => 'Failed',
			'library.stage.load' => 'Loading model',
			'library.stage.abc' => 'Planning',
			'library.stage.semantic' => 'Composing',
			'library.stage.nar' => 'Rendering',
			'library.stage.vae' => 'Decoding',
			'library.stage.transcribe' => 'Transcribing',
			_ => null,
		};
	}
}
