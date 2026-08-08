import 'dart:ui';

class LocaleStrings {
  final String appTitle;
  final String tabChat;
  final String tabKnowledge;
  final String tabInbox;
  final String tabSettings;
  final String searchHint;
  final String filterAll;
  final String manage;
  final String end;
  final String add;
  final String noArticlesYet;
  final String addFirstArticle;
  final String homeDescription;
  final String noArticlesMatch;
  final String failedToLoad;
  final String alreadySaved;
  final String savedProcessing;
  final String processed;
  final String failed;
  final String clipboardLink;
  final String clipboardSave;
  final String addArticle;
  final String addMultipleUrls;
  final String importFile;
  final String selectImages;
  final String imagePrivacyNotice;
  final String imageSelectionLimit;
  final String fileReadError;
  final String pdfExtracting;
  final String pdfNoTextFound;
  final String pdfNotSupportedOnWeb;
  final String save;
  final String supportedSources;
  final String supportedSourcesDesc;
  final String titleOptional;
  final String fetchingTitle;
  final String enterTitle;
  final String tags;
  final String typeAndPressEnter;
  final String notesOptional;
  final String addNotes;
  final String folderOptional;
  final String noFolder;
  final String saveArticle;
  final String clipboardReadError;
  final String bulkImportTitle;
  final String bulkImportDesc;
  final String addNUrls;
  final String addedNArticles;
  final String articleDetails;
  final String back;
  final String removeFromFavorites;
  final String addToFavorites;
  final String delete;
  final String deleteArticle;
  final String deleteConfirm;
  final String cancel;
  final String title;
  final String addTag;
  final String notes;
  final String folder;
  final String created;
  final String updated;
  final String addedRelative;
  final String openInBrowser;
  final String aiSummary;
  final String aiSummaryNotGenerated;
  final String aiSummaryNotAvailable;
  final String generateSummary;
  final String generating;
  final String summaryFailed;
  final String readOriginal;
  final String refresh;
  final String processing;
  final String waiting;
  final String failedSection;
  final String queued;
  final String fetchingMetadata;
  final String extractingContent;
  final String generatingSummary;
  final String generatingTags;
  final String suggestingFolder;
  final String indexing;
  final String understandingImages;
  final String retry;
  final String deleteArticleQ;
  final String removeFromInbox;
  final String inboxEmpty;
  final String inboxEmptyDesc;
  final String configureAiFirst;
  final String knowledgeBaseEmpty;
  final String notEnoughInfo;
  final String emptyAiResponse;
  final String aiError;
  final String aiNetworkError;
  final String aiTimeoutError;
  final String aiServerError;
  final String aiAuthError;
  final String aiRateLimitError;
  final String aiRequestError;
  final String aiGenericError;
  final String answerInterrupted;
  final String askKnowledgeBase;
  final String tryExamples;
  final String processFirst;
  final String askHint;
  final String tryBroaderTerm;
  final String browseKnowledgeBase;
  final String possiblyRelated;
  final String foldersTitle;
  final String newFolder;
  final String newSubfolder;
  final String folderName;
  final String folderHint;
  final String create;
  final String renameFolder;
  final String rename;
  final String deleteFolder;
  final String deleteFolderConfirm;
  final String noFoldersYet;
  final String createFoldersDesc;
  final String addSubfolder;
  final String appearance;
  final String themeMode;
  final String system;
  final String light;
  final String dark;
  final String language;
  final String summaryStyle;
  final String brief;
  final String detailed;
  final String fontSizeSection;
  final String textSize;
  final String preview;
  final String reader;
  final String defaultWebZoom;
  final String webZoomDesc;
  final String sourcePlatforms;
  final String reorderAndHide;
  final String reorderDesc;
  final String visibleInFilters;
  final String hiddenFromFilters;
  final String preferences;
  final String startupPage;
  final String startupChat;
  final String startupKnowledge;
  final String memorySortNewestFirst;
  final String memorySortNewestFirstDesc;
  final String settingsAccount;
  final String settingsAccountDesc;
  final String accountTitle;
  final String usageDays;
  final String memoryCount;
  final String tokenConsumption;
  final String accountSecurity;
  final String accountLogin;
  final String loginDesc;
  final String emailLabel;
  final String emailRequired;
  final String emailInvalid;
  final String sendCode;
  final String verifyCode;
  final String codeSentPrefix;
  final String changeEmail;
  final String logout;
  final String logoutConfirmTitle;
  final String logoutConfirm;
  final String resendCode;
  final String resendCountdown;
  final String loginErrorNetwork;
  final String loginErrorOtpInvalid;
  final String loginErrorNotConfigured;
  final String loginErrorGeneric;
  final String setPassword;
  final String changePassword;
  final String futureMembership;
  final String daysN;
  final String entriesN;
  final String detectClipboard;
  final String detectClipboardDesc;
  final String hideInboxTab;
  final String hideInboxTabDesc;
  final String aiSummarySection;
  final String apiConfig;
  final String apiConfigDesc;
  final String baseUrl;
  final String apiKey;
  final String model;
  final String aiModeByok;
  final String aiModeHosted;
  final String aiModeHostedDesc;
  final String aiModeLoginRequired;
  final String chatAiSection;
  final String imageAiSection;
  final String hostedWebSearchDesc;
  final String hostedModelLabel;
  final String saveAiSettings;
  final String aiSettingsSaved;
  final String settingsAppearance;
  final String settingsAppearanceDesc;
  final String settingsOperations;
  final String settingsOperationsDesc;
  final String settingsOther;
  final String settingsOtherDesc;
  final String settingsDev;
  final String settingsDevDesc;
  final String checkForUpdates;
  final String checkForUpdatesDesc;
  final String currentVersion;
  final String checkingForUpdates;
  final String latestVersion;
  final String newVersionAvailable;
  final String alreadyLatest;
  final String updateCheckFailed;
  final String updateNow;
  final String later;
  final String downloadingUpdate;
  final String verifyingUpdate;
  final String installingUpdate;
  final String allowInstall;
  final String allowInstallDesc;
  final String updateFailed;
  final String releaseNotes;
  final String fontWeight;
  final String operations;
  final String knowledgeSectionLabel;
  final String knowledgeBatchTitle;
  final String knowledgeify;
  final String knowledgeifyDesc;
  final String processAll;
  final String batchProcessing;
  final String allProcessed;
  final String nWithoutSummary;
  final String configureAiFirstBtn;
  final String nothingToProcess;
  final String processNArticles;
  final String setupAiProvider;
  final String batchProcessConfirm;
  final String start;
  final String processedN;
  final String embeddingSection;
  final String embeddingConfig;
  final String defaultLabel;
  final String usingBuiltIn;
  final String usingCustom;
  final String embeddingBaseUrl;
  final String embeddingApiKey;
  final String embeddingModel;
  final String testConnection;
  final String testing;
  final String connectionSuccessful;
  final String connectionFailed;
  final String resetToDefaults;
  final String fillAllFields;
  final String indexManagement;
  final String nArticlesIndexed;
  final String loadingIndexStatus;
  final String rebuildIndex;
  final String rebuilding;
  final String indexedN;
  final String configureEmbeddingFirst;
  final String data;
  final String backupRestore;
  final String backupDesc;
  final String export;
  final String import;
  final String importBackup;
  final String importConfirm;
  final String imported;
  final String invalidBackup;
  final String exportFailed;
  final String importFailed;
  final String saveFailed;
  final String editFilter;
  final String newFilter;
  final String filterName;
  final String filterNameHint;
  final String pleaseEnterName;
  final String tagKeywords;
  final String tagKeywordsDesc;
  final String addTagKeyword;
  final String sourcePlatformsFilter;
  final String sourcePlatformsDesc;
  final String manageFilters;
  final String newButton;
  final String noCustomFilters;
  final String allArticles;
  final String urlLabel;
  final String urlHint;
  final String pasteFromClipboard;
  final String pleaseEnterUrl;
  final String pleaseEnterValidUrl;
  final String detected;
  final String shareSaveTitle;
  final String saveModeFullText;
  final String saveModeAiMemory;
  final String saveModeFullTextDesc;
  final String saveModeAiMemoryDesc;
  final String shareThoughtsLabel;
  final String shareThoughtsHint;
  final String shareSaveAction;
  final String memoryLabelAi;
  final String memoryLabelOriginal;
  final String imageTranscriptionFullText;
  final String imageSourceUnavailable;
  final String regenerateAiMemoriesTitle;
  final String regenerateAiMemoriesDesc;
  final String regenerateAiMemoriesConfirm;
  final String regenerateAiMemoriesAction;
  final String nAiMemories;
  final String noAiMemoriesToRegen;
  final String chatHistory;
  final String chatNew;
  final String chatNoHistory;
  final String chatDelete;
  final String chatDeleteConfirm;
  final String chatSettings;
  final String chatAnswerLength;
  final String chatShort;
  final String chatDetailed;
  final String chatKnowledgeSource;
  final String chatKnowledgeBaseOnly;
  final String chatKbPlusGeneral;
  final String chatApply;
  final String chatTools;
  final String chatToolsWebSearch;
  final String webSearchSection;
  final String webSearchConfig;
  final String webSearchApiKey;
  final String webSearchOn;
  final String webSearchOff;
  final String webSearchNotConfigured;

  const LocaleStrings({
    required this.appTitle,
    required this.tabChat,
    required this.tabKnowledge,
    required this.tabInbox,
    required this.tabSettings,
    required this.searchHint,
    required this.filterAll,
    required this.manage,
    required this.end,
    required this.add,
    required this.noArticlesYet,
    required this.addFirstArticle,
    required this.homeDescription,
    required this.noArticlesMatch,
    required this.failedToLoad,
    required this.alreadySaved,
    required this.savedProcessing,
    required this.processed,
    required this.failed,
    required this.clipboardLink,
    required this.clipboardSave,
    required this.addArticle,
    required this.addMultipleUrls,
    required this.importFile,
    required this.selectImages,
    required this.imagePrivacyNotice,
    required this.imageSelectionLimit,
    required this.fileReadError,
    required this.pdfExtracting,
    required this.pdfNoTextFound,
    required this.pdfNotSupportedOnWeb,
    required this.save,
    required this.supportedSources,
    required this.supportedSourcesDesc,
    required this.titleOptional,
    required this.fetchingTitle,
    required this.enterTitle,
    required this.tags,
    required this.typeAndPressEnter,
    required this.notesOptional,
    required this.addNotes,
    required this.folderOptional,
    required this.noFolder,
    required this.saveArticle,
    required this.clipboardReadError,
    required this.bulkImportTitle,
    required this.bulkImportDesc,
    required this.addNUrls,
    required this.addedNArticles,
    required this.articleDetails,
    required this.back,
    required this.removeFromFavorites,
    required this.addToFavorites,
    required this.delete,
    required this.deleteArticle,
    required this.deleteConfirm,
    required this.cancel,
    required this.title,
    required this.addTag,
    required this.notes,
    required this.folder,
    required this.created,
    required this.updated,
    required this.addedRelative,
    required this.openInBrowser,
    required this.aiSummary,
    required this.aiSummaryNotGenerated,
    required this.aiSummaryNotAvailable,
    required this.generateSummary,
    required this.generating,
    required this.summaryFailed,
    required this.readOriginal,
    required this.refresh,
    required this.processing,
    required this.waiting,
    required this.failedSection,
    required this.queued,
    required this.fetchingMetadata,
    required this.extractingContent,
    required this.generatingSummary,
    required this.generatingTags,
    required this.suggestingFolder,
    required this.indexing,
    required this.understandingImages,
    required this.retry,
    required this.deleteArticleQ,
    required this.removeFromInbox,
    required this.inboxEmpty,
    required this.inboxEmptyDesc,
    required this.configureAiFirst,
    required this.knowledgeBaseEmpty,
    required this.notEnoughInfo,
    required this.emptyAiResponse,
    required this.aiError,
    required this.aiNetworkError,
    required this.aiTimeoutError,
    required this.aiServerError,
    required this.aiAuthError,
    required this.aiRateLimitError,
    required this.aiRequestError,
    required this.aiGenericError,
    required this.answerInterrupted,
    required this.askKnowledgeBase,
    required this.tryExamples,
    required this.processFirst,
    required this.askHint,
    required this.tryBroaderTerm,
    required this.browseKnowledgeBase,
    required this.possiblyRelated,
    required this.foldersTitle,
    required this.newFolder,
    required this.newSubfolder,
    required this.folderName,
    required this.folderHint,
    required this.create,
    required this.renameFolder,
    required this.rename,
    required this.deleteFolder,
    required this.deleteFolderConfirm,
    required this.noFoldersYet,
    required this.createFoldersDesc,
    required this.addSubfolder,
    required this.appearance,
    required this.themeMode,
    required this.system,
    required this.light,
    required this.dark,
    required this.language,
    required this.summaryStyle,
    required this.brief,
    required this.detailed,
    required this.fontSizeSection,
    required this.textSize,
    required this.preview,
    required this.reader,
    required this.defaultWebZoom,
    required this.webZoomDesc,
    required this.sourcePlatforms,
    required this.reorderAndHide,
    required this.reorderDesc,
    required this.visibleInFilters,
    required this.hiddenFromFilters,
    required this.preferences,
    required this.startupPage,
    required this.startupChat,
    required this.startupKnowledge,
    required this.memorySortNewestFirst,
    required this.memorySortNewestFirstDesc,
    required this.settingsAccount,
    required this.settingsAccountDesc,
    required this.accountTitle,
    required this.usageDays,
    required this.memoryCount,
    required this.tokenConsumption,
    required this.accountSecurity,
    required this.accountLogin,
    required this.loginDesc,
    required this.emailLabel,
    required this.emailRequired,
    required this.emailInvalid,
    required this.sendCode,
    required this.verifyCode,
    required this.codeSentPrefix,
    required this.changeEmail,
    required this.logout,
    required this.logoutConfirmTitle,
    required this.logoutConfirm,
    required this.resendCode,
    required this.resendCountdown,
    required this.loginErrorNetwork,
    required this.loginErrorOtpInvalid,
    required this.loginErrorNotConfigured,
    required this.loginErrorGeneric,
    required this.setPassword,
    required this.changePassword,
    required this.futureMembership,
    required this.daysN,
    required this.entriesN,
    required this.detectClipboard,
    required this.detectClipboardDesc,
    required this.hideInboxTab,
    required this.hideInboxTabDesc,
    required this.aiSummarySection,
    required this.apiConfig,
    required this.apiConfigDesc,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.aiModeByok,
    required this.aiModeHosted,
    required this.aiModeHostedDesc,
    required this.aiModeLoginRequired,
    required this.chatAiSection,
    required this.imageAiSection,
    required this.hostedWebSearchDesc,
    required this.hostedModelLabel,
    required this.saveAiSettings,
    required this.aiSettingsSaved,
    required this.settingsAppearance,
    required this.settingsAppearanceDesc,
    required this.settingsOperations,
    required this.settingsOperationsDesc,
    required this.settingsOther,
    required this.settingsOtherDesc,
    required this.settingsDev,
    required this.settingsDevDesc,
    required this.checkForUpdates,
    required this.checkForUpdatesDesc,
    required this.currentVersion,
    required this.checkingForUpdates,
    required this.latestVersion,
    required this.newVersionAvailable,
    required this.alreadyLatest,
    required this.updateCheckFailed,
    required this.updateNow,
    required this.later,
    required this.downloadingUpdate,
    required this.verifyingUpdate,
    required this.installingUpdate,
    required this.allowInstall,
    required this.allowInstallDesc,
    required this.updateFailed,
    required this.releaseNotes,
    required this.fontWeight,
    required this.operations,
    required this.knowledgeSectionLabel,
    required this.knowledgeBatchTitle,
    required this.knowledgeify,
    required this.knowledgeifyDesc,
    required this.processAll,
    required this.batchProcessing,
    required this.allProcessed,
    required this.nWithoutSummary,
    required this.configureAiFirstBtn,
    required this.nothingToProcess,
    required this.processNArticles,
    required this.setupAiProvider,
    required this.batchProcessConfirm,
    required this.start,
    required this.processedN,
    required this.embeddingSection,
    required this.embeddingConfig,
    required this.defaultLabel,
    required this.usingBuiltIn,
    required this.usingCustom,
    required this.embeddingBaseUrl,
    required this.embeddingApiKey,
    required this.embeddingModel,
    required this.testConnection,
    required this.testing,
    required this.connectionSuccessful,
    required this.connectionFailed,
    required this.resetToDefaults,
    required this.fillAllFields,
    required this.indexManagement,
    required this.nArticlesIndexed,
    required this.loadingIndexStatus,
    required this.rebuildIndex,
    required this.rebuilding,
    required this.indexedN,
    required this.configureEmbeddingFirst,
    required this.data,
    required this.backupRestore,
    required this.backupDesc,
    required this.export,
    required this.import,
    required this.importBackup,
    required this.importConfirm,
    required this.imported,
    required this.invalidBackup,
    required this.exportFailed,
    required this.importFailed,
    required this.saveFailed,
    required this.editFilter,
    required this.newFilter,
    required this.filterName,
    required this.filterNameHint,
    required this.pleaseEnterName,
    required this.tagKeywords,
    required this.tagKeywordsDesc,
    required this.addTagKeyword,
    required this.sourcePlatformsFilter,
    required this.sourcePlatformsDesc,
    required this.manageFilters,
    required this.newButton,
    required this.noCustomFilters,
    required this.allArticles,
    required this.urlLabel,
    required this.urlHint,
    required this.pasteFromClipboard,
    required this.pleaseEnterUrl,
    required this.pleaseEnterValidUrl,
    required this.detected,
    required this.shareSaveTitle,
    required this.saveModeFullText,
    required this.saveModeAiMemory,
    required this.saveModeFullTextDesc,
    required this.saveModeAiMemoryDesc,
    required this.shareThoughtsLabel,
    required this.shareThoughtsHint,
    required this.shareSaveAction,
    required this.memoryLabelAi,
    required this.memoryLabelOriginal,
    required this.imageTranscriptionFullText,
    required this.imageSourceUnavailable,
    required this.regenerateAiMemoriesTitle,
    required this.regenerateAiMemoriesDesc,
    required this.regenerateAiMemoriesConfirm,
    required this.regenerateAiMemoriesAction,
    required this.nAiMemories,
    required this.noAiMemoriesToRegen,
    required this.chatHistory,
    required this.chatNew,
    required this.chatNoHistory,
    required this.chatDelete,
    required this.chatDeleteConfirm,
    required this.chatSettings,
    required this.chatAnswerLength,
    required this.chatShort,
    required this.chatDetailed,
    required this.chatKnowledgeSource,
    required this.chatKnowledgeBaseOnly,
    required this.chatKbPlusGeneral,
    required this.chatApply,
    required this.chatTools,
    required this.chatToolsWebSearch,
    required this.webSearchSection,
    required this.webSearchConfig,
    required this.webSearchApiKey,
    required this.webSearchOn,
    required this.webSearchOff,
    required this.webSearchNotConfigured,
  });

  static LocaleStrings of(int languageIndex, {Locale? deviceLocale}) {
    switch (languageIndex) {
      case 1:
        return _zh;
      case 2:
        return _en;
      default:
        // Follow system locale
        final locale = deviceLocale ?? PlatformDispatcher.instance.locale;
        if (locale.languageCode == 'zh') return _zh;
        return _en;
    }
  }

  static const _en = LocaleStrings(
    appTitle: 'Memora',
    tabChat: 'Recall',
    tabKnowledge: 'Memory',
    tabInbox: 'Progress',
    tabSettings: 'Settings',
    searchHint: 'Search memories, tags or notes...',
    filterAll: 'All',
    manage: 'Manage',
    end: 'End',
    add: 'Add',
    noArticlesYet: 'No memories yet',
    addFirstArticle:
        'Add your first memory to start building your knowledge base.',
    homeDescription:
        'One share to know. Turn scattered content from any platform into traceable, recallable personal memory.',
    noArticlesMatch: 'No memories match the current filters',
    failedToLoad: 'Failed to load memories',
    alreadySaved: 'Already saved',
    savedProcessing: 'Saved — processing in background',
    processed: 'Processed',
    failed: 'Failed',
    clipboardLink: 'Link found on clipboard',
    clipboardSave: 'Save',
    addArticle: 'Add Memory',
    addMultipleUrls: 'Add multiple URLs',
    importFile: 'Import File',
    selectImages: 'Select images',
    imagePrivacyNotice:
        'When Memora official AI is enabled, selected images pass through the Memora server and are processed by the model you choose. When it is disabled, images are sent directly to your configured image-understanding service. Without a configured service, they are saved only as local attachments. Continue?',
    imageSelectionLimit: 'You can select up to 9 images.',
    fileReadError: 'Failed to read file',
    pdfExtracting: 'Extracting PDF text...',
    pdfNoTextFound: 'No extractable text in PDF (may be a scanned document)',
    pdfNotSupportedOnWeb: 'PDF import is not supported on Web',
    save: 'Save',
    supportedSources: 'Supported sources',
    supportedSourcesDesc:
        'Paste links from your enabled platforms and the app will detect the source automatically.',
    titleOptional: 'Title (optional)',
    fetchingTitle: 'Fetching title...',
    enterTitle: 'Enter a title for this memory',
    tags: 'Tags',
    typeAndPressEnter: 'Type and press Enter to add',
    notesOptional: 'Notes (optional)',
    addNotes: 'Add any notes about this memory',
    folderOptional: 'Folder (optional)',
    noFolder: 'No folder',
    saveArticle: 'Save memory',
    clipboardReadError: 'Could not read from clipboard',
    bulkImportTitle: 'Add multiple URLs',
    bulkImportDesc:
        'Paste one URL per line (or separated by spaces/commas). Sources are detected automatically.',
    addNUrls: 'Add',
    addedNArticles: 'Added',
    articleDetails: 'Memory Details',
    back: 'Back',
    removeFromFavorites: 'Remove from favorites',
    addToFavorites: 'Add to favorites',
    delete: 'Delete',
    deleteArticle: 'Delete Memory',
    deleteConfirm:
        'Are you sure you want to delete this memory? This action cannot be undone.',
    cancel: 'Cancel',
    title: 'Title',
    addTag: 'Add tag',
    notes: 'Notes',
    folder: 'Folder',
    created: 'Created',
    updated: 'Updated',
    addedRelative: 'Added',
    openInBrowser: 'Open in browser',
    aiSummary: 'AI Memory',
    aiSummaryNotGenerated: 'AI memory not yet generated.',
    aiSummaryNotAvailable:
        'AI memory not available. Configure AI in Settings to enable.',
    generateSummary: 'Generate Memory',
    generating: 'Generating...',
    summaryFailed:
        'Memory generation failed. Check your model API configuration.',
    readOriginal: 'Read Original',
    refresh: 'Refresh',
    processing: 'Processing',
    waiting: 'Waiting',
    failedSection: 'Failed',
    queued: 'Queued',
    fetchingMetadata: 'Fetching metadata',
    extractingContent: 'Extracting content',
    generatingSummary: 'Generating memory',
    generatingTags: 'Generating tags',
    suggestingFolder: 'Suggesting folder',
    indexing: 'Indexing',
    understandingImages: 'Understanding images',
    retry: 'Retry',
    deleteArticleQ: 'Delete memory?',
    removeFromInbox: 'Remove from progress?',
    inboxEmpty: 'No memories in progress',
    inboxEmptyDesc: 'Memories being processed will appear here.',
    configureAiFirst: 'Please configure your AI provider in Settings first.',
    knowledgeBaseEmpty:
        'Your Memora is empty. Process some memories first, then come back to ask questions.',
    notEnoughInfo:
        'I couldn\'t find enough relevant information in your Memora to answer this question.',
    emptyAiResponse:
        'The AI service returned an empty response. Please try again.',
    aiError: 'Error communicating with AI service',
    aiNetworkError:
        'The network connection was interrupted while generating this answer. Check your connection and tap “Retry”.',
    aiTimeoutError:
        'The AI service took too long to respond. Please tap “Retry” in a moment.',
    aiServerError:
        'The AI service is temporarily unavailable. Please try again in a moment.',
    aiAuthError:
        'The AI service could not authenticate this request. Check your AI settings or sign in again.',
    aiRateLimitError:
        'The AI service request limit has been reached. Please try again later.',
    aiRequestError:
        'The AI service could not process this request. Check your model settings and try again.',
    aiGenericError:
        'The AI service could not finish this answer. Please tap “Retry”.',
    answerInterrupted: 'The previous answer was interrupted while generating.',
    askKnowledgeBase: 'Explore your Memora',
    tryExamples:
        'Try: "What are the key ideas about AI?" or "Summarize my saved memories on Flutter"',
    processFirst:
        'Process some memories first, then come back to ask questions.',
    askHint: 'Ask about your knowledge...',
    tryBroaderTerm: 'Try a broader term:',
    browseKnowledgeBase: 'Browse Memora',
    possiblyRelated: 'Possibly related:',
    foldersTitle: 'Folders',
    newFolder: 'New Folder',
    newSubfolder: 'New Subfolder',
    folderName: 'Folder name',
    folderHint: 'e.g. Tech, Reading List',
    create: 'Create',
    renameFolder: 'Rename Folder',
    rename: 'Rename',
    deleteFolder: 'Delete Folder',
    deleteFolderConfirm:
        'Delete this folder? Memories in this folder will become unfiled.',
    noFoldersYet: 'No folders yet',
    createFoldersDesc: 'Create folders to organize your memories',
    addSubfolder: 'Add subfolder',
    appearance: 'Appearance',
    themeMode: 'Theme Mode',
    system: 'System',
    light: 'Light',
    dark: 'Dark',
    language: 'Language',
    summaryStyle: 'Memory Style',
    brief: 'Brief',
    detailed: 'Detailed',
    fontSizeSection: 'Font Size',
    textSize: 'Text Size',
    preview: 'Preview: The quick brown fox jumps over the lazy dog.',
    reader: 'Reader',
    defaultWebZoom: 'Default Web Zoom',
    webZoomDesc:
        'Controls the initial zoom level when opening memories in the built-in browser.',
    sourcePlatforms: 'Source Platforms',
    reorderAndHide: 'Reorder And Hide',
    reorderDesc:
        'Drag to change the chip order. Turn off platforms you do not want to see in filters.',
    visibleInFilters: 'Visible in filters',
    hiddenFromFilters: 'Hidden from filters',
    preferences: 'Preferences',
    startupPage: 'Open on startup',
    startupChat: 'Chat',
    startupKnowledge: 'Memora',
    memorySortNewestFirst: 'Newest memories first',
    memorySortNewestFirstDesc:
        'Turn off to show the earliest created memories first.',
    settingsAccount: 'Account',
    settingsAccountDesc: 'Usage stats, security settings',
    accountTitle: 'Account',
    usageDays: 'Days active',
    memoryCount: 'Memory items',
    tokenConsumption: 'Token consumption',
    accountSecurity: 'Account Security',
    accountLogin: 'Sign in / Sign up',
    loginDesc: 'Enter your email to receive a one-time verification code.',
    emailLabel: 'Email',
    emailRequired: 'Please enter your email',
    emailInvalid: 'Please enter a valid email',
    sendCode: 'Send verification code',
    verifyCode: 'Verify',
    codeSentPrefix: 'Verification code sent to',
    changeEmail: 'Change email',
    logout: 'Sign out',
    logoutConfirmTitle: 'Sign out',
    logoutConfirm: 'Are you sure you want to sign out?',
    resendCode: 'Resend code',
    resendCountdown: 'Resend in {}s',
    loginErrorNetwork:
        'Network error. Please check your connection and try again.',
    loginErrorOtpInvalid:
        'Invalid or expired verification code. Please try again.',
    loginErrorNotConfigured:
        'Login service is not configured. Please contact support.',
    loginErrorGeneric: 'Login failed. Please try again later.',
    setPassword: 'Set Password',
    changePassword: 'Change Password',
    futureMembership: 'Future membership tiers',
    daysN: 'days',
    entriesN: 'entries',
    detectClipboard: 'Detect links from clipboard',
    detectClipboardDesc:
        'When you open the app, offer to save a link you have copied.',
    hideInboxTab: 'Hide "Progress" Tab',
    hideInboxTabDesc: 'Remove the Progress tab from the bottom navigation bar',
    aiSummarySection: 'AI Memory',
    apiConfig: 'API Configuration',
    apiConfigDesc:
        'Enter your OpenAI-compatible API credentials. Your key is stored on this device only and is never included in exported backups.',
    baseUrl: 'Base URL',
    apiKey: 'API Key',
    model: 'Model',
    aiModeByok: 'Own API key',
    aiModeHosted: 'Memora Service',
    aiModeHostedDesc: 'Use AI models and web search provided by Memora.',
    aiModeLoginRequired: 'Sign in to use Memora AI.',
    chatAiSection: 'AI Chat',
    imageAiSection: 'Image Understanding',
    hostedWebSearchDesc: 'Web search is provided by the Memora server.',
    hostedModelLabel: 'Model Selection',
    saveAiSettings: 'Save AI Settings',
    aiSettingsSaved: 'AI settings saved',
    settingsAppearance: 'Appearance',
    settingsAppearanceDesc: 'Theme, language, font size & more',
    settingsOperations: 'Memory',
    settingsOperationsDesc: 'Memory style, batch processing, index & more',
    settingsOther: 'Other',
    settingsOtherDesc: 'Source platforms, backup & restore',
    settingsDev: 'Feedback Stats',
    settingsDevDesc: 'Response feedback data (dev)',
    checkForUpdates: 'Check for Updates',
    checkForUpdatesDesc: 'Current version',
    currentVersion: 'Current version',
    checkingForUpdates: 'Checking for updates…',
    latestVersion: 'Latest version',
    newVersionAvailable: 'New Version Available',
    alreadyLatest: 'You are using the latest version.',
    updateCheckFailed: 'Could not check for updates. Try again later.',
    updateNow: 'Update Now',
    later: 'Later',
    downloadingUpdate: 'Downloading update…',
    verifyingUpdate: 'Verifying update…',
    installingUpdate: 'Opening the system installer…',
    allowInstall: 'Allow Installation',
    allowInstallDesc:
        'Allow Memora to install updates, then return to continue.',
    updateFailed: 'Update failed. Please try again.',
    releaseNotes: 'What’s New',
    fontWeight: 'Font Weight',
    operations: 'Memories',
    knowledgeSectionLabel: 'Memory Management',
    knowledgeBatchTitle: 'Backfill AI Memories',
    knowledgeify: 'Knowledge-ify Old Memories',
    knowledgeifyDesc: 'Generate memories for all items that are missing them.',
    processAll: 'Process All',
    batchProcessing: 'Batch Processing',
    allProcessed: 'All memories have been processed.',
    nWithoutSummary: 'memory without AI memory',
    configureAiFirstBtn: 'Configure AI first',
    nothingToProcess: 'Nothing to process',
    processNArticles: 'Process item(s)',
    setupAiProvider:
        'Set up your AI provider above to enable batch processing.',
    batchProcessConfirm:
        'Process item(s)? This will call your AI provider for each to generate memories and tags.',
    start: 'Start',
    processedN: 'Processed',
    embeddingSection: 'Vector Model',
    embeddingConfig: 'Vector Model Configuration',
    defaultLabel: 'Default',
    usingBuiltIn:
        'Vectorization is provided by Memora. You can also bring your own OpenAI-compatible endpoint.',
    usingCustom: 'Using your custom OpenAI-compatible vector endpoint.',
    embeddingBaseUrl: 'Vector Model URL',
    embeddingApiKey: 'Vector Model API Key',
    embeddingModel: 'Vector Model',
    testConnection: 'Test Connection',
    testing: 'Testing...',
    connectionSuccessful: 'Connection successful',
    connectionFailed: 'Connection failed — check config',
    resetToDefaults: 'Reset to Defaults',
    fillAllFields: 'Fill in all fields first',
    indexManagement: 'Index Management',
    nArticlesIndexed: 'memories indexed',
    loadingIndexStatus: 'Loading index status...',
    rebuildIndex: 'Rebuild Index',
    rebuilding: 'Rebuilding...',
    indexedN: 'Indexed',
    configureEmbeddingFirst: 'Configure the vector model first',
    data: 'Data',
    backupRestore: 'Backup & Restore',
    backupDesc:
        'Export all your articles, filters and settings to a JSON file, or import a backup. Importing merges into your current data.',
    export: 'Export',
    import: 'Import',
    importBackup: 'Import backup',
    importConfirm:
        'Articles and filters from the backup will be merged into your current data. App settings will be replaced. Continue?',
    imported: 'Imported',
    invalidBackup: 'Invalid backup file',
    exportFailed: 'Export failed',
    importFailed: 'Import failed',
    saveFailed: 'Save failed',
    editFilter: 'Edit Filter',
    newFilter: 'New Filter',
    filterName: 'Filter Name',
    filterNameHint: 'e.g. "Tech Articles", "Favorites"',
    pleaseEnterName: 'Please enter a filter name',
    tagKeywords: 'Tag Keywords',
    tagKeywordsDesc: 'Memories matching any of these tags will be included.',
    addTagKeyword: 'Add tag keyword',
    sourcePlatformsFilter: 'Source Platforms',
    sourcePlatformsDesc:
        'Leave empty to include all sources, or select specific ones.',
    manageFilters: 'Manage Filters',
    newButton: 'New',
    noCustomFilters: 'No custom filters yet',
    allArticles: 'All articles',
    urlLabel: 'URL',
    urlHint: 'https://x.com/... or https://www.bilibili.com/...',
    pasteFromClipboard: 'Paste from clipboard',
    pleaseEnterUrl: 'Please enter a URL',
    pleaseEnterValidUrl: 'Please enter a valid URL',
    detected: 'Detected',
    shareSaveTitle: 'Save to Memora',
    saveModeFullText: 'Full text',
    saveModeAiMemory: 'AI memory',
    saveModeFullTextDesc:
        'Keep the full article text. Title, tags and folder still use AI.',
    saveModeAiMemoryDesc: 'Generate an AI memory as your memory card.',
    shareThoughtsLabel: 'Thoughts right now',
    shareThoughtsHint: 'Jot down your thoughts — saved as your personal note',
    shareSaveAction: 'Save',
    memoryLabelAi: 'AI memory',
    memoryLabelOriginal: 'Original memory',
    imageTranscriptionFullText: 'Image transcription',
    imageSourceUnavailable: 'The original image is unavailable on this device.',
    regenerateAiMemoriesTitle: 'Regenerate AI Memories',
    regenerateAiMemoriesDesc:
        'Re-run AI summary for all AI-memory items (skips full-text / original memories).',
    regenerateAiMemoriesConfirm:
        'Regenerate AI memory for these items? This will call your AI provider for each one.',
    regenerateAiMemoriesAction: 'Regenerate All',
    nAiMemories: 'AI-memory item(s)',
    noAiMemoriesToRegen: 'No AI memories to regenerate',
    chatHistory: 'Chat History',
    chatNew: 'New Chat',
    chatNoHistory: 'No saved chats yet',
    chatDelete: 'Delete Chat',
    chatDeleteConfirm: 'Delete this chat and all of its local messages?',
    chatSettings: 'Chat Settings',
    chatAnswerLength: 'Answer Length',
    chatShort: 'Short',
    chatDetailed: 'Detailed',
    chatKnowledgeSource: 'Knowledge Source',
    chatKnowledgeBaseOnly: 'Knowledge Base Only',
    chatKbPlusGeneral: 'KB + General',
    chatApply: 'Apply',
    chatTools: 'Tools',
    chatToolsWebSearch: 'Web Search',
    webSearchSection: 'Web Search',
    webSearchConfig: 'Web Search (Tavily)',
    webSearchApiKey: 'Tavily API Key',
    webSearchOn: 'Web search on — answers may include live sources',
    webSearchOff: 'Web search off',
    webSearchNotConfigured:
        'Set a Tavily API key in Settings > API to enable web search',
  );

  static const _zh = LocaleStrings(
    appTitle: '记忆海',
    tabChat: '回忆',
    tabKnowledge: '记忆',
    tabInbox: '进程',
    tabSettings: '设置',
    searchHint: '搜索记忆、标签或笔记…',
    filterAll: '全部',
    manage: '管理',
    end: '末尾',
    add: '添加',
    noArticlesYet: '暂无记忆',
    addFirstArticle: '添加你的第一条记忆，开始建立个人知识库。',
    homeDescription: '一键分享即知识化，将散落各平台的内容转化为可追溯、可召回的个人记忆。',
    noArticlesMatch: '没有记忆匹配当前筛选条件',
    failedToLoad: '加载记忆失败',
    alreadySaved: '已保存',
    savedProcessing: '已保存，后台处理中',
    processed: '已处理',
    failed: '失败',
    clipboardLink: '剪贴板链接',
    clipboardSave: '保存',
    addArticle: '添加记忆',
    addMultipleUrls: '添加多个链接',
    importFile: '导入文件',
    selectImages: '选择图片',
    imagePrivacyNotice:
        '开启记忆海官方 AI 时，所选图片经过记忆海服务器，由你选择的模型进行处理；关闭时，图片会直接发送至你配置的识图服务。若未配置，则仅保存为本地附件。是否继续？',
    imageSelectionLimit: '最多选择 9 张图片。',
    fileReadError: '无法读取文件',
    pdfExtracting: '正在提取 PDF 文本…',
    pdfNoTextFound: 'PDF 无可提取文本（可能是扫描件）',
    pdfNotSupportedOnWeb: 'Web 端暂不支持 PDF 导入',
    save: '保存',
    supportedSources: '支持的来源',
    supportedSourcesDesc: '从已启用的平台粘贴链接，应用会自动识别来源。',
    titleOptional: '标题（可选）',
    fetchingTitle: '正在获取标题…',
    enterTitle: '输入标题',
    tags: '标签',
    typeAndPressEnter: '输入后按回车添加',
    notesOptional: '备注（可选）',
    addNotes: '添加关于此记忆的备注',
    folderOptional: '文件夹（可选）',
    noFolder: '无文件夹',
    saveArticle: '保存记忆',
    clipboardReadError: '无法读取剪贴板',
    bulkImportTitle: '添加多个链接',
    bulkImportDesc: '每行粘贴一个链接（或用空格/逗号分隔）。来源会自动识别。',
    addNUrls: '添加',
    addedNArticles: '已添加',
    articleDetails: '记忆详情',
    back: '返回',
    removeFromFavorites: '取消收藏',
    addToFavorites: '添加收藏',
    delete: '删除',
    deleteArticle: '删除记忆',
    deleteConfirm: '确定要删除此记忆吗？此操作不可撤销。',
    cancel: '取消',
    title: '标题',
    addTag: '添加标签',
    notes: '备注',
    folder: '文件夹',
    created: '创建时间',
    updated: '更新时间',
    addedRelative: '添加于',
    openInBrowser: '在浏览器中打开',
    aiSummary: 'AI 摘要',
    aiSummaryNotGenerated: 'AI 摘要尚未生成。',
    aiSummaryNotAvailable: 'AI 摘要不可用。请在设置中配置 AI。',
    generateSummary: '生成摘要',
    generating: '生成中…',
    summaryFailed: '摘要生成失败，请检查模型api配置。',
    readOriginal: '阅读原文',
    refresh: '刷新',
    processing: '处理中',
    waiting: '等待中',
    failedSection: '失败',
    queued: '已排队',
    fetchingMetadata: '获取元数据',
    extractingContent: '提取内容',
    generatingSummary: '生成摘要',
    generatingTags: '生成标签',
    suggestingFolder: '推荐文件夹',
    indexing: '索引中',
    understandingImages: '正在理解图片',
    retry: '重试',
    deleteArticleQ: '删除记忆？',
    removeFromInbox: '从进程移除？',
    inboxEmpty: '无处理中的记忆',
    inboxEmptyDesc: '正在处理的记忆会显示在此处。',
    configureAiFirst: '请先在设置中配置 AI。',
    knowledgeBaseEmpty: '记忆海为空。请先处理一些记忆，然后再来提问。',
    notEnoughInfo: '在记忆海中找不到足够的相关信息来回答此问题。',
    emptyAiResponse: 'AI 服务返回了空响应，请重试。',
    aiError: '与 AI 服务通信出错',
    aiNetworkError: '生成回答时网络连接中断，请检查网络后点击“重试”重新生成。',
    aiTimeoutError: 'AI 服务响应时间过长，请稍后点击“重试”重新生成。',
    aiServerError: 'AI 服务暂时繁忙或不可用，请稍后点击“重试”。',
    aiAuthError: 'AI 服务认证失败，请检查 AI 配置或重新登录。',
    aiRateLimitError: 'AI 服务请求次数已达限制，请稍后再试。',
    aiRequestError: 'AI 服务无法处理这次请求，请检查模型配置后重试。',
    aiGenericError: 'AI 暂时没有完成这个回答，请点击“重试”重新生成。',
    answerInterrupted: '上次回答在生成中被中断。',
    askKnowledgeBase: '探索我的记忆海',
    tryExamples: '试试：「关于 AI 的核心观点是什么？」或「总结我保存的 Flutter 记忆」',
    processFirst: '请先处理一些记忆，然后再来提问。',
    askHint: '你想知道些什么？',
    tryBroaderTerm: '试试更宽泛的词：',
    browseKnowledgeBase: '浏览记忆海',
    possiblyRelated: '可能相关：',
    foldersTitle: '文件夹',
    newFolder: '新建文件夹',
    newSubfolder: '新建子文件夹',
    folderName: '文件夹名称',
    folderHint: '例如：技术、阅读清单',
    create: '创建',
    renameFolder: '重命名文件夹',
    rename: '重命名',
    deleteFolder: '删除文件夹',
    deleteFolderConfirm: '删除此文件夹？文件夹中的记忆将变为未归档。',
    noFoldersYet: '暂无文件夹',
    createFoldersDesc: '创建文件夹来整理记忆',
    addSubfolder: '添加子文件夹',
    appearance: '外观',
    themeMode: '主题模式',
    system: '跟随系统',
    light: '浅色',
    dark: '深色',
    language: '语言',
    summaryStyle: '记忆风格',
    brief: '简洁',
    detailed: '详细',
    fontSizeSection: '字体大小',
    textSize: '文字大小',
    preview: '预览：敏捷的棕色狐狸跳过了懒狗。',
    reader: '阅读器',
    defaultWebZoom: '默认网页缩放',
    webZoomDesc: '控制在内置浏览器中打开记忆时的初始缩放级别。',
    sourcePlatforms: '来源平台',
    reorderAndHide: '排序与隐藏',
    reorderDesc: '拖动以调整标签顺序。关闭不想在筛选中看到的平台。',
    visibleInFilters: '筛选中可见',
    hiddenFromFilters: '筛选中隐藏',
    preferences: '偏好',
    startupPage: '启动时打开',
    startupChat: '回忆',
    startupKnowledge: '记忆',
    memorySortNewestFirst: '最新记忆优先',
    memorySortNewestFirstDesc: '关闭后，最早创建的记忆排在最上面。',
    settingsAccount: '账号',
    settingsAccountDesc: '使用统计、安全设置',
    accountTitle: '账号',
    usageDays: '已使用',
    memoryCount: '记忆数量',
    tokenConsumption: 'Token 消耗',
    accountSecurity: '账号安全',
    accountLogin: '登录 / 注册',
    loginDesc: '输入邮箱，我们将发送一次性验证码。',
    emailLabel: '邮箱',
    emailRequired: '请输入邮箱地址',
    emailInvalid: '请输入有效的邮箱地址',
    sendCode: '发送验证码',
    verifyCode: '验证',
    codeSentPrefix: '验证码已发送至',
    changeEmail: '更换邮箱',
    logout: '退出登录',
    logoutConfirmTitle: '退出登录',
    logoutConfirm: '确定要退出登录吗？',
    resendCode: '重新发送',
    resendCountdown: '{}秒后可重发',
    loginErrorNetwork: '网络错误，请检查网络后重试。',
    loginErrorOtpInvalid: '验证码无效或已过期，请重试。',
    loginErrorNotConfigured: '登录服务未配置，请联系管理员。',
    loginErrorGeneric: '登录失败，请稍后重试。',
    setPassword: '设置密码',
    changePassword: '修改密码',
    futureMembership: '未来会员等级勋章',
    daysN: '天',
    entriesN: '条',
    detectClipboard: '检测剪贴板链接',
    detectClipboardDesc: '打开应用时，提示保存已复制的链接。',
    hideInboxTab: '隐藏"进程"标签',
    hideInboxTabDesc: '从底部导航栏移除进程入口',
    aiSummarySection: 'AI 摘要',
    apiConfig: 'API 配置',
    apiConfigDesc: '输入你的OpenAI兼容API配置。密钥仅存储在本地。',
    baseUrl: '基础 URL',
    apiKey: 'API 密钥',
    model: '模型',
    aiModeByok: '自己的 API 密钥',
    aiModeHosted: '记忆海服务',
    aiModeHostedDesc: '使用记忆海提供的AI模型与联网搜索。',
    aiModeLoginRequired: '登录后才能使用记忆海 AI。',
    chatAiSection: 'AI 对话',
    imageAiSection: '识图模型',
    hostedWebSearchDesc: '联网搜索由记忆海服务器提供。',
    hostedModelLabel: '模型选择',
    saveAiSettings: '保存 AI 设置',
    aiSettingsSaved: 'AI 设置已保存',
    settingsAppearance: '界面',
    settingsAppearanceDesc: '主题、语言、字体大小等',
    settingsOperations: '记忆',
    settingsOperationsDesc: '批量处理、索引、剪贴板等',
    settingsOther: '其他',
    settingsOtherDesc: '来源平台、备份与恢复',
    settingsDev: '反馈统计',
    settingsDevDesc: '对话反馈数据（开发用）',
    checkForUpdates: '检查更新',
    checkForUpdatesDesc: '当前版本',
    currentVersion: '当前版本',
    checkingForUpdates: '正在检查更新…',
    latestVersion: '最新版本',
    newVersionAvailable: '发现新版本',
    alreadyLatest: '当前已是最新版本',
    updateCheckFailed: '检查更新失败，请稍后重试',
    updateNow: '立即更新',
    later: '稍后',
    downloadingUpdate: '正在下载更新…',
    verifyingUpdate: '正在校验安装包…',
    installingUpdate: '正在打开系统安装界面…',
    allowInstall: '允许安装',
    allowInstallDesc: '请允许记忆海安装更新，授权后返回即可继续。',
    updateFailed: '更新失败，请重试',
    releaseNotes: '更新内容',
    fontWeight: '字体粗细',
    operations: '记忆',
    knowledgeSectionLabel: '记忆管理',
    knowledgeBatchTitle: '补充生成 AI 记忆',
    knowledgeify: '批量知识化旧记忆',
    knowledgeifyDesc: '为所有未生成 AI 记忆的条目补全记忆',
    processAll: '全部处理',
    batchProcessing: '批量处理',
    allProcessed: '所有记忆已处理完毕。',
    nWithoutSummary: '条记忆未补全',
    configureAiFirstBtn: '请先配置 AI',
    nothingToProcess: '没有需要处理的',
    processNArticles: '处理条记忆',
    setupAiProvider: '请在上方设置 AI 以启用批量处理。',
    batchProcessConfirm: '处理条记忆？这将调用你的 AI 为每条记忆补充生成内容和标签。',
    start: '开始',
    processedN: '已处理',
    embeddingSection: '向量化模型',
    embeddingConfig: '向量化模型配置',
    defaultLabel: '默认',
    usingBuiltIn: '向量化由记忆海提供。你也可以使用自定义的 OpenAI 兼容端点。',
    usingCustom: '使用自定义 OpenAI 兼容向量化端点。',
    embeddingBaseUrl: '向量化模型 URL',
    embeddingApiKey: '向量化模型 API 密钥',
    embeddingModel: '向量化模型',
    testConnection: '测试连接',
    testing: '测试中…',
    connectionSuccessful: '连接成功',
    connectionFailed: '连接失败，请检查配置',
    resetToDefaults: '恢复默认',
    fillAllFields: '请先填写所有字段',
    indexManagement: '索引管理',
    nArticlesIndexed: '条记忆已索引',
    loadingIndexStatus: '加载索引状态…',
    rebuildIndex: '重建索引',
    rebuilding: '重建中…',
    indexedN: '已索引',
    configureEmbeddingFirst: '请先配置向量化模型',
    data: '数据',
    backupRestore: '备份与恢复',
    backupDesc: '导出所有记忆、筛选和设置到 JSON 文件，或导入备份。导入会合并到当前数据。',
    export: '导出',
    import: '导入',
    importBackup: '导入备份',
    importConfirm: '备份中的记忆和筛选将合并到当前数据。应用设置将被替换。继续？',
    imported: '已导入',
    invalidBackup: '无效备份文件',
    exportFailed: '导出失败',
    importFailed: '导入失败',
    saveFailed: '保存失败',
    editFilter: '编辑筛选',
    newFilter: '新建筛选',
    filterName: '筛选名称',
    filterNameHint: '例如：「技术记忆」「收藏」',
    pleaseEnterName: '请输入筛选名称',
    tagKeywords: '标签关键词',
    tagKeywordsDesc: '匹配任一标签的记忆将被包含。',
    addTagKeyword: '添加标签关键词',
    sourcePlatformsFilter: '来源平台',
    sourcePlatformsDesc: '留空以包含所有来源，或选择特定来源。',
    manageFilters: '管理筛选',
    newButton: '新建',
    noCustomFilters: '暂无自定义筛选',
    allArticles: '所有记忆',
    urlLabel: '链接',
    urlHint: 'https://x.com/... 或 https://www.bilibili.com/...',
    pasteFromClipboard: '从剪贴板粘贴',
    pleaseEnterUrl: '请输入链接',
    pleaseEnterValidUrl: '请输入有效链接',
    detected: '已识别',
    shareSaveTitle: '保存到记忆海',
    saveModeFullText: '全文保存',
    saveModeAiMemory: 'AI 记忆',
    saveModeFullTextDesc: '保留文章全文。标题、标签和文件夹仍会用 AI 生成。',
    saveModeAiMemoryDesc: '生成 AI 摘要作为记忆卡片。',
    shareThoughtsLabel: '此时的想法',
    shareThoughtsHint: '记下此刻的想法——会保存为你的个人备注',
    shareSaveAction: '保存',
    memoryLabelAi: 'AI 记忆',
    memoryLabelOriginal: '原始记忆',
    imageTranscriptionFullText: '图片转写全文',
    imageSourceUnavailable: '原始图片未在此设备上同步。',
    regenerateAiMemoriesTitle: '重新生成 AI 记忆',
    regenerateAiMemoriesDesc: '为所有 AI 记忆条目重新生成摘要（跳过全文/原始记忆）。',
    regenerateAiMemoriesConfirm: '为这些条目重新生成 AI 记忆？将为每条调用 AI。',
    regenerateAiMemoriesAction: '全部重新生成',
    nAiMemories: '条 AI 记忆',
    noAiMemoriesToRegen: '没有可重新生成的 AI 记忆',
    chatHistory: '对话历史',
    chatNew: '新建对话',
    chatNoHistory: '暂无已保存的对话',
    chatDelete: '删除对话',
    chatDeleteConfirm: '删除此对话及其全部本地消息？',
    chatSettings: '对话设置',
    chatAnswerLength: '回答长度',
    chatShort: '简洁',
    chatDetailed: '详细',
    chatKnowledgeSource: '知识来源',
    chatKnowledgeBaseOnly: '仅知识库',
    chatKbPlusGeneral: '知识库 + 通用',
    chatApply: '应用',
    chatTools: '工具',
    chatToolsWebSearch: '联网搜索',
    webSearchSection: '联网搜索',
    webSearchConfig: '联网搜索（Tavily）',
    webSearchApiKey: 'Tavily API Key',
    webSearchOn: '已开启联网搜索 — 回答可能引用实时来源',
    webSearchOff: '未开启联网搜索',
    webSearchNotConfigured: '请在 设置-API 中配置 Tavily API Key 以启用联网搜索',
  );
}
