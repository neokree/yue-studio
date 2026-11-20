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
	late final Translations$requirements$en requirements = Translations$requirements$en._(_root);
	late final Translations$create$en create = Translations$create$en._(_root);
	late final Translations$cover$en cover = Translations$cover$en._(_root);
	late final Translations$library$en library = Translations$library$en._(_root);
	late final Translations$score$en score = Translations$score$en._(_root);
	late final Translations$player$en player = Translations$player$en._(_root);
	late final Translations$generation$en generation = Translations$generation$en._(_root);
	late final Translations$shell$en shell = Translations$shell$en._(_root);
}

// Path: app
class Translations$app$en {
	Translations$app$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'YuE² Studio'
	String get title => 'YuE² Studio';

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

	/// en: 'Setting up YuE'
	String get titlePre => 'Setting up YuE';

	/// en: ' Studio'
	String get titlePost => ' Studio';

	/// en: 'Your private-first music generation studio. Music is generated locally.'
	String get subtitle => 'Your private-first music generation studio. Music is generated locally.';

	/// en: 'Install'
	String get install => 'Install';

	/// en: 'Retry'
	String get retry => 'Retry';

	/// en: 'Total download'
	String get totalDownload => 'Total download';

	/// en: '$done of $total'
	String progress({required Object done, required Object total}) => '${done} of ${total}';

	/// en: 'Not enough free disk space. Setup needs $need and only $free is available. Free up space, then press Retry.'
	String noDisk({required Object need, required Object free}) => 'Not enough free disk space. Setup needs ${need} and only ${free} is available. Free up space, then press Retry.';

	/// en: 'Check again'
	String get recheck => 'Check again';

	late final Translations$setup$preflight$en preflight = Translations$setup$preflight$en._(_root);

	/// en: 'Unofficial client, not affiliated with the YuE2 authors.'
	String get fine => 'Unofficial client, not affiliated with the YuE2 authors.';

	late final Translations$setup$phase$en phase = Translations$setup$phase$en._(_root);

	/// en: 'Everything is installed. Opening your studio.'
	String get ready => 'Everything is installed. Opening your studio.';

	/// en: 'Couldn't finish $step.'
	String stepFailed({required Object step}) => 'Couldn\'t finish ${step}.';

	/// en: 'Check your internet connection and free disk space, then press Retry. Finished steps are kept and setup continues from here.'
	String get recovery => 'Check your internet connection and free disk space, then press Retry. Finished steps are kept and setup continues from here.';
}

// Path: requirements
class Translations$requirements$en {
	Translations$requirements$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'YuE'
	String get titlePre => 'YuE';

	/// en: ' Studio minimum requirements not met'
	String get titlePost => ' Studio minimum requirements not met';

	/// en: 'YuE'
	String get statementPre => 'YuE';

	/// en: ' Studio needs at least $gb GB of RAM to work properly'
	String statementPost({required Object gb}) => ' Studio needs at least ${gb} GB of RAM to work properly';

	/// en: 'Your Mac has'
	String get yourMac => 'Your Mac has';

	/// en: 'Try anyway'
	String get tryAnyway => 'Try anyway';
}

// Path: create
class Translations$create$en {
	Translations$create$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Create'
	String get title => 'Create';

	/// en: 'Title'
	String get titleLabel => 'Title';

	/// en: '(Optional)'
	String get optional => '(Optional)';

	/// en: 'Empty uses the first lyric line, or Untitled and the date.'
	String get titleHint => 'Empty uses the first lyric line, or Untitled and the date.';

	/// en: 'Style'
	String get style => 'Style';

	/// en: 'Genre, instruments, voice, language, tempo'
	String get styleHint => 'Genre, instruments, voice, language, tempo';

	/// en: 'English, warm piano pop, expressive female voice, acoustic piano, 88 BPM'
	String get stylePlaceholder => 'English, warm piano pop, expressive female voice, acoustic piano, 88 BPM';

	/// en: 'Lyrics'
	String get lyrics => 'Lyrics';

	/// en: 'Use [Verse] and [Chorus]. Leave empty for instrumental.'
	String get lyricsHint => 'Use [Verse] and [Chorus]. Leave empty for instrumental.';

	/// en: '[Verse] Write your lyrics here [Chorus] ...'
	String get lyricsPlaceholder => '[Verse]\nWrite your lyrics here\n\n[Chorus]\n...';

	/// en: 'Plan'
	String get plan => 'Plan';

	/// en: 'Melody + chords'
	String get planFull => 'Melody + chords';

	/// en: 'Melody'
	String get planMelody => 'Melody';

	/// en: 'None'
	String get planOff => 'None';

	/// en: 'Seed'
	String get seed => 'Seed';

	/// en: 'random'
	String get seedHint => 'random';

	/// en: '~ $time'
	String estimate({required Object time}) => '~ ${time}';

	/// en: 'Estimated time on this Mac'
	String get estimateTip => 'Estimated time on this Mac';

	/// en: 'Add to Queue'
	String get generate => 'Add to Queue';

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

	/// en: 'Choose a recording'
	String get pick => 'Choose a recording';

	/// en: 'A wav, flac, mp3 or ogg file to cover.'
	String get pickHint => 'A wav, flac, mp3 or ogg file to cover.';

	/// en: 'Audio'
	String get pickDialog => 'Audio';

	/// en: 'Replace'
	String get replace => 'Replace';

	/// en: 'Remove'
	String get remove => 'Remove';

	/// en: 'No recording yet'
	String get noFile => 'No recording yet';

	/// en: '$size · $length · $state'
	String meta({required Object size, required Object length, required Object state}) => '${size} · ${length} · ${state}';

	/// en: 'not transcribed'
	String get stateIdle => 'not transcribed';

	/// en: 'transcribing'
	String get stateWorking => 'transcribing';

	/// en: 'score ready'
	String get stateReady => 'score ready';

	/// en: 'Score'
	String get scoreTitle => 'Score';

	/// en: 'From the recording, or paste your own'
	String get scoreHint => 'From the recording, or paste your own';

	/// en: 'Close'
	String get modeClose => 'Close';

	/// en: 'Free'
	String get modeFree => 'Free';

	/// en: 'Free: melody only. Close: melody and chords.'
	String get modeHint => 'Free: melody only. Close: melody and chords.';

	/// en: 'Transcribe'
	String get transcribe => 'Transcribe';

	/// en: 'Transcribing, this takes about a minute.'
	String get transcribing => 'Transcribing, this takes about a minute.';

	/// en: 'Could not transcribe: $message. Check the file and try again.'
	String transcribeFailed({required Object message}) => 'Could not transcribe: ${message}. Check the file and try again.';

	/// en: 'Cover description'
	String get styleTitle => 'Cover description';

	/// en: 'The new mood and arrangement'
	String get styleHint => 'The new mood and arrangement';

	/// en: 'Italian, acoustic folk, warm female voice, fingerpicked guitar, 80 BPM'
	String get stylePlaceholder => 'Italian, acoustic folk, warm female voice, fingerpicked guitar, 80 BPM';

	/// en: 'Lyrics'
	String get lyricsTitle => 'Lyrics';

	/// en: 'In the order of the score's sections'
	String get lyricsHint => 'In the order of the score\'s sections';

	/// en: '[Verse] Write your lyrics here [Chorus] ...'
	String get lyricsPlaceholder => '[Verse]\nWrite your lyrics here\n\n[Chorus]\n...';

	/// en: 'Seed'
	String get seed => 'Seed';

	/// en: 'random'
	String get seedHint => 'random';

	/// en: '~ $time'
	String estimate({required Object time}) => '~ ${time}';

	/// en: 'Estimated time on this Mac'
	String get estimateTip => 'Estimated time on this Mac';

	/// en: 'Add to Queue'
	String get generate => 'Add to Queue';

	/// en: 'Added to the queue'
	String get queued => 'Added to the queue';

	/// en: 'Choose a recording first.'
	String get needFile => 'Choose a recording first.';

	/// en: 'Transcribe the recording or paste a score first.'
	String get needScore => 'Transcribe the recording or paste a score first.';

	/// en: 'Describe the new style first.'
	String get needStyle => 'Describe the new style first.';

	/// en: 'Write the lyrics first.'
	String get needLyrics => 'Write the lyrics first.';

	/// en: 'Title'
	String get titleLabel => 'Title';

	/// en: '(Optional)'
	String get optional => '(Optional)';

	/// en: 'Defaults to the first lyric line'
	String get titleHint => 'Defaults to the first lyric line';

	/// en: 'Untitled'
	String get titlePlaceholder => 'Untitled';

	/// en: 'Choose a recording for an estimate'
	String get estimateIdle => 'Choose a recording for an estimate';
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

	/// en: 'Write a style and lyrics in Create, then add the song to the queue.'
	String get emptyHint => 'Write a style and lyrics in Create, then add the song to the queue.';

	/// en: 'Go to Create'
	String get goCreate => 'Go to Create';

	/// en: 'No liked songs yet'
	String get emptyLiked => 'No liked songs yet';

	/// en: 'Tap the heart next to a song to like it. Liked songs appear here.'
	String get emptyLikedHint => 'Tap the heart next to a song to like it. Liked songs appear here.';

	late final Translations$library$filter$en filter = Translations$library$filter$en._(_root);
	late final Translations$library$col$en col = Translations$library$col$en._(_root);
	late final Translations$library$menu$en menu = Translations$library$menu$en._(_root);

	/// en: 'Play'
	String get play => 'Play';

	/// en: 'Pause'
	String get pause => 'Pause';

	/// en: 'Like'
	String get like => 'Like';

	/// en: 'Remove from Liked'
	String get unlike => 'Remove from Liked';

	/// en: 'Cover'
	String get cover => 'Cover';

	/// en: 'Delete "$title"?'
	String deleteTitle({required Object title}) => 'Delete "${title}"?';

	/// en: 'The audio and the score are removed from this Mac. This cannot be undone.'
	String get deleteBody => 'The audio and the score are removed from this Mac. This cannot be undone.';

	/// en: 'Delete'
	String get deleteConfirm => 'Delete';

	/// en: 'Cancel'
	String get dismiss => 'Cancel';

	/// en: 'Song title'
	String get renameLabel => 'Song title';

	/// en: 'Score'
	String get scoreTitle => 'Score';

	/// en: 'Close'
	String get close => 'Close';

	/// en: 'This song has no score.'
	String get noScore => 'This song has no score.';

	/// en: 'Could not export the audio: $message'
	String exportFailed({required Object message}) => 'Could not export the audio: ${message}';

	/// en: 'Today, $time'
	String today({required Object time}) => 'Today, ${time}';

	/// en: 'Yesterday'
	String get yesterday => 'Yesterday';

	/// en: 'Step $done of $total'
	String step({required Object done, required Object total}) => 'Step ${done} of ${total}';

	/// en: '$time left'
	String timeLeft({required Object time}) => '${time} left';

	/// en: 'About $time'
	String eta({required Object time}) => 'About ${time}';
}

// Path: score
class Translations$score$en {
	Translations$score$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Notation'
	String get notation => 'Notation';

	/// en: 'Text'
	String get text => 'Text';

	/// en: 'No score yet. Transcribe a recording or paste ABC text.'
	String get empty => 'No score yet. Transcribe a recording or paste ABC text.';

	/// en: 'Notation preview is not available here, showing the text.'
	String get unavailable => 'Notation preview is not available here, showing the text.';

	/// en: 'Paste an ABC score here'
	String get placeholder => 'Paste an ABC score here';
}

// Path: player
class Translations$player$en {
	Translations$player$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Nothing playing'
	String get empty => 'Nothing playing';

	/// en: 'Previous'
	String get previous => 'Previous';

	/// en: 'Next'
	String get next => 'Next';

	/// en: 'Play'
	String get play => 'Play';

	/// en: 'Pause'
	String get pause => 'Pause';

	/// en: 'Like'
	String get like => 'Like';

	/// en: 'Remove from Liked'
	String get unlike => 'Remove from Liked';
}

// Path: generation
class Translations$generation$en {
	Translations$generation$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Score'
	String get stageScore => 'Score';

	/// en: 'Melody'
	String get stageMelody => 'Melody';

	/// en: 'Sound'
	String get stageSound => 'Sound';

	/// en: 'Master'
	String get stageMaster => 'Master';

	/// en: 'Starting'
	String get starting => 'Starting';

	/// en: 'Done'
	String get done => 'Done';

	/// en: '$status · about $time left'
	String timeLeft({required Object status, required Object time}) => '${status} · about ${time} left';

	/// en: 'Cancel'
	String get cancel => 'Cancel';

	/// en: 'Cancelling'
	String get cancelling => 'Cancelling';

	/// en: 'Nothing is being generated.'
	String get idle => 'Nothing is being generated.';

	/// en: 'a few seconds'
	String get fewSeconds => 'a few seconds';

	/// en: '$s s'
	String durSec({required Object s}) => '${s} s';

	/// en: '$m min'
	String durMin({required Object m}) => '${m} min';

	/// en: '$m min $s s'
	String durMinSec({required Object m, required Object s}) => '${m} min ${s} s';

	/// en: '$status · a few seconds left'
	String timeLeftFew({required Object status}) => '${status} · a few seconds left';

	/// en: '$stage, done'
	String stageDoneLabel({required Object stage}) => '${stage}, done';

	/// en: '$stage, $pct%'
	String statusPct({required Object stage, required Object pct}) => '${stage}, ${pct}%';

	/// en: '$stage, step $done of $total'
	String statusStep({required Object stage, required Object done, required Object total}) => '${stage}, step ${done} of ${total}';
}

// Path: shell
class Translations$shell$en {
	Translations$shell$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations
	late final Translations$shell$brand$en brand = Translations$shell$brand$en._(_root);
	late final Translations$shell$nav$en nav = Translations$shell$nav$en._(_root);
	late final Translations$shell$queue$en queue = Translations$shell$queue$en._(_root);
	late final Translations$shell$stage$en stage = Translations$shell$stage$en._(_root);
	late final Translations$shell$time$en time = Translations$shell$time$en._(_root);
}

// Path: setup.preflight
class Translations$setup$preflight$en {
	Translations$setup$preflight$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Only $have of disk space is free. Setup needs at least $need free. Free up space, then press Check again.'
	String disk({required Object have, required Object need}) => 'Only ${have} of disk space is free. Setup needs at least ${need} free. Free up space, then press Check again.';
}

// Path: setup.phase
class Translations$setup$phase$en {
	Translations$setup$phase$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Connecting'
	String get connecting => 'Connecting';

	/// en: 'Installing Python'
	String get python => 'Installing Python';

	/// en: 'Creating environment'
	String get venv => 'Creating environment';

	/// en: 'Installing packages'
	String get packages => 'Installing packages';
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

// Path: library.filter
class Translations$library$filter$en {
	Translations$library$filter$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'All'
	String get all => 'All';

	/// en: 'Liked'
	String get liked => 'Liked';
}

// Path: library.col
class Translations$library$col$en {
	Translations$library$col$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Title'
	String get title => 'Title';

	/// en: 'Created'
	String get created => 'Created';

	/// en: 'Length'
	String get length => 'Length';
}

// Path: library.menu
class Translations$library$menu$en {
	Translations$library$menu$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Rename'
	String get rename => 'Rename';

	/// en: 'Reuse Style and Lyrics'
	String get reuse => 'Reuse Style and Lyrics';

	/// en: 'Export Audio'
	String get export => 'Export Audio';

	/// en: 'Show Score'
	String get score => 'Show Score';

	/// en: 'Delete'
	String get delete => 'Delete';

	/// en: 'Cancel Job'
	String get cancel => 'Cancel Job';

	/// en: 'More actions'
	String get more => 'More actions';
}

// Path: shell.brand
class Translations$shell$brand$en {
	Translations$shell$brand$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'YuE'
	String get main => 'YuE';

	/// en: '2'
	String get sup => '2';

	/// en: 'Studio'
	String get studio => 'Studio';
}

// Path: shell.nav
class Translations$shell$nav$en {
	Translations$shell$nav$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Create'
	String get create => 'Create';

	/// en: 'Cover'
	String get cover => 'Cover';

	/// en: 'Library'
	String get libraryGroup => 'Library';

	/// en: 'All Songs'
	String get allSongs => 'All Songs';

	/// en: 'Liked'
	String get liked => 'Liked';
}

// Path: shell.queue
class Translations$shell$queue$en {
	Translations$shell$queue$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Nothing in the queue'
	String get idle => 'Nothing in the queue';

	/// en: 'Starting'
	String get starting => 'Starting';

	/// en: '$stage, step $done of $total'
	String step({required Object stage, required Object done, required Object total}) => '${stage}, step ${done} of ${total}';

	/// en: '$n queued'
	String queued({required Object n}) => '${n} queued';

	/// en: 'About $time left'
	String remaining({required Object time}) => 'About ${time} left';

	/// en: 'Cancelled'
	String get cancelled => 'Cancelled';

	/// en: 'The engine failed to start: $message'
	String engineFailed({required Object message}) => 'The engine failed to start: ${message}';

	/// en: 'The engine did not produce a score.'
	String get noScore => 'The engine did not produce a score.';
}

// Path: shell.stage
class Translations$shell$stage$en {
	Translations$shell$stage$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Loading model'
	String get load => 'Loading model';

	/// en: 'Planning score'
	String get abc => 'Planning score';

	/// en: 'Composing melody'
	String get semantic => 'Composing melody';

	/// en: 'Rendering sound'
	String get nar => 'Rendering sound';

	/// en: 'Mastering'
	String get vae => 'Mastering';

	/// en: 'Transcribing'
	String get transcribe => 'Transcribing';
}

// Path: shell.time
class Translations$shell$time$en {
	Translations$shell$time$en._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: '$m min $s s'
	String minSec({required Object m, required Object s}) => '${m} min ${s} s';

	/// en: '$m min'
	String min({required Object m}) => '${m} min';

	/// en: '$s s'
	String sec({required Object s}) => '${s} s';
}

/// The flat map containing all translations for locale <en>.
/// Only for edge cases! For simple maps, use the map function of this library.
///
/// The Dart AOT compiler has issues with very large switch statements,
/// so the map is split into smaller functions (512 entries each).
extension on Translations {
	dynamic _flatMapFunction(String path) {
		return switch (path) {
			'app.title' => 'YuE² Studio',
			'app.unofficial' => 'Unofficial client. Not affiliated with the YuE2 authors.',
			'nav.create' => 'Create',
			'nav.cover' => 'Cover',
			'nav.library' => 'Library',
			'setup.titlePre' => 'Setting up YuE',
			'setup.titlePost' => ' Studio',
			'setup.subtitle' => 'Your private-first music generation studio. Music is generated locally.',
			'setup.install' => 'Install',
			'setup.retry' => 'Retry',
			'setup.totalDownload' => 'Total download',
			'setup.progress' => ({required Object done, required Object total}) => '${done} of ${total}',
			'setup.noDisk' => ({required Object need, required Object free}) => 'Not enough free disk space. Setup needs ${need} and only ${free} is available. Free up space, then press Retry.',
			'setup.recheck' => 'Check again',
			'setup.preflight.disk' => ({required Object have, required Object need}) => 'Only ${have} of disk space is free. Setup needs at least ${need} free. Free up space, then press Check again.',
			'setup.fine' => 'Unofficial client, not affiliated with the YuE2 authors.',
			'setup.phase.connecting' => 'Connecting',
			'setup.phase.python' => 'Installing Python',
			'setup.phase.venv' => 'Creating environment',
			'setup.phase.packages' => 'Installing packages',
			'setup.ready' => 'Everything is installed. Opening your studio.',
			'setup.stepFailed' => ({required Object step}) => 'Couldn\'t finish ${step}.',
			'setup.recovery' => 'Check your internet connection and free disk space, then press Retry. Finished steps are kept and setup continues from here.',
			'requirements.titlePre' => 'YuE',
			'requirements.titlePost' => ' Studio minimum requirements not met',
			'requirements.statementPre' => 'YuE',
			'requirements.statementPost' => ({required Object gb}) => ' Studio needs at least ${gb} GB of RAM to work properly',
			'requirements.yourMac' => 'Your Mac has',
			'requirements.tryAnyway' => 'Try anyway',
			'create.title' => 'Create',
			'create.titleLabel' => 'Title',
			'create.optional' => '(Optional)',
			'create.titleHint' => 'Empty uses the first lyric line, or Untitled and the date.',
			'create.style' => 'Style',
			'create.styleHint' => 'Genre, instruments, voice, language, tempo',
			'create.stylePlaceholder' => 'English, warm piano pop, expressive female voice, acoustic piano, 88 BPM',
			'create.lyrics' => 'Lyrics',
			'create.lyricsHint' => 'Use [Verse] and [Chorus]. Leave empty for instrumental.',
			'create.lyricsPlaceholder' => '[Verse]\nWrite your lyrics here\n\n[Chorus]\n...',
			'create.plan' => 'Plan',
			'create.planFull' => 'Melody + chords',
			'create.planMelody' => 'Melody',
			'create.planOff' => 'None',
			'create.seed' => 'Seed',
			'create.seedHint' => 'random',
			'create.estimate' => ({required Object time}) => '~ ${time}',
			'create.estimateTip' => 'Estimated time on this Mac',
			'create.generate' => 'Add to Queue',
			'create.untitled' => 'Untitled',
			'cover.title' => 'Cover',
			'cover.pick' => 'Choose a recording',
			'cover.pickHint' => 'A wav, flac, mp3 or ogg file to cover.',
			'cover.pickDialog' => 'Audio',
			'cover.replace' => 'Replace',
			'cover.remove' => 'Remove',
			'cover.noFile' => 'No recording yet',
			'cover.meta' => ({required Object size, required Object length, required Object state}) => '${size} · ${length} · ${state}',
			'cover.stateIdle' => 'not transcribed',
			'cover.stateWorking' => 'transcribing',
			'cover.stateReady' => 'score ready',
			'cover.scoreTitle' => 'Score',
			'cover.scoreHint' => 'From the recording, or paste your own',
			'cover.modeClose' => 'Close',
			'cover.modeFree' => 'Free',
			'cover.modeHint' => 'Free: melody only. Close: melody and chords.',
			'cover.transcribe' => 'Transcribe',
			'cover.transcribing' => 'Transcribing, this takes about a minute.',
			'cover.transcribeFailed' => ({required Object message}) => 'Could not transcribe: ${message}. Check the file and try again.',
			'cover.styleTitle' => 'Cover description',
			'cover.styleHint' => 'The new mood and arrangement',
			'cover.stylePlaceholder' => 'Italian, acoustic folk, warm female voice, fingerpicked guitar, 80 BPM',
			'cover.lyricsTitle' => 'Lyrics',
			'cover.lyricsHint' => 'In the order of the score\'s sections',
			'cover.lyricsPlaceholder' => '[Verse]\nWrite your lyrics here\n\n[Chorus]\n...',
			'cover.seed' => 'Seed',
			'cover.seedHint' => 'random',
			'cover.estimate' => ({required Object time}) => '~ ${time}',
			'cover.estimateTip' => 'Estimated time on this Mac',
			'cover.generate' => 'Add to Queue',
			'cover.queued' => 'Added to the queue',
			'cover.needFile' => 'Choose a recording first.',
			'cover.needScore' => 'Transcribe the recording or paste a score first.',
			'cover.needStyle' => 'Describe the new style first.',
			'cover.needLyrics' => 'Write the lyrics first.',
			'cover.titleLabel' => 'Title',
			'cover.optional' => '(Optional)',
			'cover.titleHint' => 'Defaults to the first lyric line',
			'cover.titlePlaceholder' => 'Untitled',
			'cover.estimateIdle' => 'Choose a recording for an estimate',
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
			'library.emptyHint' => 'Write a style and lyrics in Create, then add the song to the queue.',
			'library.goCreate' => 'Go to Create',
			'library.emptyLiked' => 'No liked songs yet',
			'library.emptyLikedHint' => 'Tap the heart next to a song to like it. Liked songs appear here.',
			'library.filter.all' => 'All',
			'library.filter.liked' => 'Liked',
			'library.col.title' => 'Title',
			'library.col.created' => 'Created',
			'library.col.length' => 'Length',
			'library.menu.rename' => 'Rename',
			'library.menu.reuse' => 'Reuse Style and Lyrics',
			'library.menu.export' => 'Export Audio',
			'library.menu.score' => 'Show Score',
			'library.menu.delete' => 'Delete',
			'library.menu.cancel' => 'Cancel Job',
			'library.menu.more' => 'More actions',
			'library.play' => 'Play',
			'library.pause' => 'Pause',
			'library.like' => 'Like',
			'library.unlike' => 'Remove from Liked',
			'library.cover' => 'Cover',
			'library.deleteTitle' => ({required Object title}) => 'Delete "${title}"?',
			'library.deleteBody' => 'The audio and the score are removed from this Mac. This cannot be undone.',
			'library.deleteConfirm' => 'Delete',
			'library.dismiss' => 'Cancel',
			'library.renameLabel' => 'Song title',
			'library.scoreTitle' => 'Score',
			'library.close' => 'Close',
			'library.noScore' => 'This song has no score.',
			'library.exportFailed' => ({required Object message}) => 'Could not export the audio: ${message}',
			'library.today' => ({required Object time}) => 'Today, ${time}',
			'library.yesterday' => 'Yesterday',
			'library.step' => ({required Object done, required Object total}) => 'Step ${done} of ${total}',
			'library.timeLeft' => ({required Object time}) => '${time} left',
			'library.eta' => ({required Object time}) => 'About ${time}',
			'score.notation' => 'Notation',
			'score.text' => 'Text',
			'score.empty' => 'No score yet. Transcribe a recording or paste ABC text.',
			'score.unavailable' => 'Notation preview is not available here, showing the text.',
			'score.placeholder' => 'Paste an ABC score here',
			'player.empty' => 'Nothing playing',
			'player.previous' => 'Previous',
			'player.next' => 'Next',
			'player.play' => 'Play',
			'player.pause' => 'Pause',
			'player.like' => 'Like',
			'player.unlike' => 'Remove from Liked',
			'generation.stageScore' => 'Score',
			'generation.stageMelody' => 'Melody',
			'generation.stageSound' => 'Sound',
			'generation.stageMaster' => 'Master',
			'generation.starting' => 'Starting',
			'generation.done' => 'Done',
			'generation.timeLeft' => ({required Object status, required Object time}) => '${status} · about ${time} left',
			'generation.cancel' => 'Cancel',
			'generation.cancelling' => 'Cancelling',
			'generation.idle' => 'Nothing is being generated.',
			'generation.fewSeconds' => 'a few seconds',
			'generation.durSec' => ({required Object s}) => '${s} s',
			'generation.durMin' => ({required Object m}) => '${m} min',
			'generation.durMinSec' => ({required Object m, required Object s}) => '${m} min ${s} s',
			'generation.timeLeftFew' => ({required Object status}) => '${status} · a few seconds left',
			'generation.stageDoneLabel' => ({required Object stage}) => '${stage}, done',
			'generation.statusPct' => ({required Object stage, required Object pct}) => '${stage}, ${pct}%',
			'generation.statusStep' => ({required Object stage, required Object done, required Object total}) => '${stage}, step ${done} of ${total}',
			'shell.brand.main' => 'YuE',
			'shell.brand.sup' => '2',
			'shell.brand.studio' => 'Studio',
			'shell.nav.create' => 'Create',
			'shell.nav.cover' => 'Cover',
			'shell.nav.libraryGroup' => 'Library',
			'shell.nav.allSongs' => 'All Songs',
			'shell.nav.liked' => 'Liked',
			'shell.queue.idle' => 'Nothing in the queue',
			'shell.queue.starting' => 'Starting',
			'shell.queue.step' => ({required Object stage, required Object done, required Object total}) => '${stage}, step ${done} of ${total}',
			'shell.queue.queued' => ({required Object n}) => '${n} queued',
			'shell.queue.remaining' => ({required Object time}) => 'About ${time} left',
			'shell.queue.cancelled' => 'Cancelled',
			'shell.queue.engineFailed' => ({required Object message}) => 'The engine failed to start: ${message}',
			'shell.queue.noScore' => 'The engine did not produce a score.',
			'shell.stage.load' => 'Loading model',
			'shell.stage.abc' => 'Planning score',
			'shell.stage.semantic' => 'Composing melody',
			'shell.stage.nar' => 'Rendering sound',
			'shell.stage.vae' => 'Mastering',
			'shell.stage.transcribe' => 'Transcribing',
			'shell.time.minSec' => ({required Object m, required Object s}) => '${m} min ${s} s',
			'shell.time.min' => ({required Object m}) => '${m} min',
			'shell.time.sec' => ({required Object s}) => '${s} s',
			_ => null,
		};
	}
}
