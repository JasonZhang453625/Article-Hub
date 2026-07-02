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
  final String settingsAccount;
  final String settingsAccountDesc;
  final String accountTitle;
  final String usageDays;
  final String memoryCount;
  final String tokenConsumption;
  final String accountSecurity;
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
    required this.settingsAccount,
    required this.settingsAccountDesc,
    required this.accountTitle,
    required this.usageDays,
    required this.memoryCount,
    required this.tokenConsumption,
    required this.accountSecurity,
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
    tabChat: 'Chat',
    tabKnowledge: 'Memora',
    tabInbox: 'Progress',
    tabSettings: 'Settings',
    searchHint: 'Search articles, tags or notes...',
    filterAll: 'All',
    manage: 'Manage',
    end: 'End',
    add: 'Add',
    noArticlesYet: 'No articles yet',
    addFirstArticle: 'Add your first article to build a calmer, better organized reading queue.',
    homeDescription: 'Save articles from X, Bilibili, Rednote, ChatGPT, WeChat and the wider web in one clean place.',
    noArticlesMatch: 'No articles match the current filters',
    failedToLoad: 'Failed to load articles',
    alreadySaved: 'Already saved',
    savedProcessing: 'Saved — processing in background',
    processed: 'Processed',
    failed: 'Failed',
    clipboardLink: 'Link found on clipboard',
    clipboardSave: 'Save',
    addArticle: 'Add Article',
    addMultipleUrls: 'Add multiple URLs',
    save: 'Save',
    supportedSources: 'Supported sources',
    supportedSourcesDesc: 'Paste links from your enabled platforms and the app will detect the source automatically.',
    titleOptional: 'Title (optional)',
    fetchingTitle: 'Fetching title...',
    enterTitle: 'Enter a title for this article',
    tags: 'Tags',
    typeAndPressEnter: 'Type and press Enter to add',
    notesOptional: 'Notes (optional)',
    addNotes: 'Add any notes about this article',
    folderOptional: 'Folder (optional)',
    noFolder: 'No folder',
    saveArticle: 'Save article',
    clipboardReadError: 'Could not read from clipboard',
    bulkImportTitle: 'Add multiple URLs',
    bulkImportDesc: 'Paste one URL per line (or separated by spaces/commas). Sources are detected automatically.',
    addNUrls: 'Add',
    addedNArticles: 'Added',
    articleDetails: 'Article Details',
    back: 'Back',
    removeFromFavorites: 'Remove from favorites',
    addToFavorites: 'Add to favorites',
    delete: 'Delete',
    deleteArticle: 'Delete Article',
    deleteConfirm: 'Are you sure you want to delete this article? This action cannot be undone.',
    cancel: 'Cancel',
    title: 'Title',
    addTag: 'Add tag',
    notes: 'Notes',
    folder: 'Folder',
    created: 'Created',
    updated: 'Updated',
    addedRelative: 'Added',
    openInBrowser: 'Open in browser',
    aiSummary: 'AI Summary',
    aiSummaryNotGenerated: 'AI summary not yet generated.',
    aiSummaryNotAvailable: 'AI summary not available. Configure AI in Settings to enable.',
    generateSummary: 'Generate Summary',
    generating: 'Generating...',
    summaryFailed: 'Summary generation failed. Check your AI settings.',
    readOriginal: 'Read Original',
    refresh: 'Refresh',
    processing: 'Processing',
    waiting: 'Waiting',
    failedSection: 'Failed',
    queued: 'Queued',
    fetchingMetadata: 'Fetching metadata',
    extractingContent: 'Extracting content',
    generatingSummary: 'Generating summary',
    generatingTags: 'Generating tags',
    suggestingFolder: 'Suggesting folder',
    indexing: 'Indexing',
    retry: 'Retry',
    deleteArticleQ: 'Delete article?',
    removeFromInbox: 'Remove from progress?',
    inboxEmpty: 'No articles in progress',
    inboxEmptyDesc: 'Articles being processed will appear here.',
    configureAiFirst: 'Please configure your AI provider in Settings first.',
    knowledgeBaseEmpty: 'Your Memora is empty. Process some articles first, then come back to ask questions.',
    notEnoughInfo: 'I couldn\'t find enough relevant information in your Memora to answer this question.',
    emptyAiResponse: 'The AI service returned an empty response. Please try again.',
    aiError: 'Error communicating with AI service',
    askKnowledgeBase: 'Ask your Memora',
    tryExamples: 'Try: "What are the key ideas about AI?" or "Summarize my saved articles on Flutter"',
    processFirst: 'Process some articles first, then come back to ask questions.',
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
    deleteFolderConfirm: 'Delete this folder? Articles in this folder will become unfiled.',
    noFoldersYet: 'No folders yet',
    createFoldersDesc: 'Create folders to organize your articles',
    addSubfolder: 'Add subfolder',
    appearance: 'Appearance',
    themeMode: 'Theme Mode',
    system: 'System',
    light: 'Light',
    dark: 'Dark',
    language: 'Language',
    summaryStyle: 'Summary Style',
    brief: 'Brief',
    detailed: 'Detailed',
    fontSizeSection: 'Font Size',
    textSize: 'Text Size',
    preview: 'Preview: The quick brown fox jumps over the lazy dog.',
    reader: 'Reader',
    defaultWebZoom: 'Default Web Zoom',
    webZoomDesc: 'Controls the initial zoom level when opening articles in the built-in browser.',
    sourcePlatforms: 'Source Platforms',
    reorderAndHide: 'Reorder And Hide',
    reorderDesc: 'Drag to change the chip order. Turn off platforms you do not want to see in filters.',
    visibleInFilters: 'Visible in filters',
    hiddenFromFilters: 'Hidden from filters',
    preferences: 'Preferences',
    startupPage: 'Open on startup',
    startupChat: 'Chat',
    startupKnowledge: 'Memora',
    settingsAccount: 'Account',
    settingsAccountDesc: 'Usage stats, security settings',
    accountTitle: 'Account',
    usageDays: 'Days active',
    memoryCount: 'Memory items',
    tokenConsumption: 'Token consumption',
    accountSecurity: 'Account Security',
    setPassword: 'Set Password',
    changePassword: 'Change Password',
    futureMembership: 'Future membership tiers',
    daysN: 'days',
    entriesN: 'entries',
    detectClipboard: 'Detect links from clipboard',
    detectClipboardDesc: 'When you open the app, offer to save a link you have copied.',
    hideInboxTab: 'Hide "Progress" Tab',
    hideInboxTabDesc: 'Remove the Progress tab from the bottom navigation bar',
    aiSummarySection: 'AI Summary',
    apiConfig: 'API Configuration',
    apiConfigDesc: 'Enter your OpenAI-compatible API credentials. Your key is stored on this device only and is never included in exported backups.',
    baseUrl: 'Base URL',
    apiKey: 'API Key',
    model: 'Model',
    saveAiSettings: 'Save AI Settings',
    aiSettingsSaved: 'AI settings saved',
    settingsAppearance: 'Appearance',
    settingsAppearanceDesc: 'Theme, language, font size & more',
    settingsOperations: 'Summary',
    settingsOperationsDesc: 'Summary style, batch processing, index & more',
    settingsOther: 'Other',
    settingsOtherDesc: 'Source platforms, backup & restore',
    settingsDev: 'Feedback Stats',
    settingsDevDesc: 'Response feedback data (dev)',
    fontWeight: 'Font Weight',
    operations: 'Operations',
    knowledgeSectionLabel: 'Memory Management',
    knowledgeBatchTitle: 'Backfill Summaries',
    knowledgeify: 'Knowledge-ify Old Articles',
    knowledgeifyDesc: 'Generate summaries for all articles that are missing them.',
    processAll: 'Process All',
    batchProcessing: 'Batch Processing',
    allProcessed: 'All articles have been processed.',
    nWithoutSummary: 'article(s) without a summary',
    configureAiFirstBtn: 'Configure AI first',
    nothingToProcess: 'Nothing to process',
    processNArticles: 'Process article(s)',
    setupAiProvider: 'Set up your AI provider above to enable batch processing.',
    batchProcessConfirm: 'Process article(s)? This will call your AI provider for each article to generate summaries and tags.',
    start: 'Start',
    processedN: 'Processed',
    embeddingSection: 'Embedding & Index',
    embeddingConfig: 'Embedding Configuration',
    defaultLabel: 'Default',
    usingBuiltIn: 'Using built-in embedding service. You can also bring your own OpenAI-compatible endpoint.',
    usingCustom: 'Using your custom OpenAI-compatible embeddings endpoint.',
    embeddingBaseUrl: 'Embedding Base URL',
    embeddingApiKey: 'Embedding API Key',
    embeddingModel: 'Embedding Model',
    testConnection: 'Test Connection',
    testing: 'Testing...',
    connectionSuccessful: 'Connection successful',
    connectionFailed: 'Connection failed — check config',
    resetToDefaults: 'Reset to Defaults',
    fillAllFields: 'Fill in all fields first',
    indexManagement: 'Index Management',
    nArticlesIndexed: 'articles indexed',
    loadingIndexStatus: 'Loading index status...',
    rebuildIndex: 'Rebuild Index',
    rebuilding: 'Rebuilding...',
    indexedN: 'Indexed',
    configureEmbeddingFirst: 'Configure embedding first',
    data: 'Data',
    backupRestore: 'Backup & Restore',
    backupDesc: 'Export all your articles, filters and settings to a JSON file, or import a backup. Importing merges into your current data.',
    export: 'Export',
    import: 'Import',
    importBackup: 'Import backup',
    importConfirm: 'Articles and filters from the backup will be merged into your current data. App settings will be replaced. Continue?',
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
    tagKeywordsDesc: 'Articles matching any of these tags will be included.',
    addTagKeyword: 'Add tag keyword',
    sourcePlatformsFilter: 'Source Platforms',
    sourcePlatformsDesc: 'Leave empty to include all sources, or select specific ones.',
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
  );

  static const _zh = LocaleStrings(
    appTitle: '记忆海',
    tabChat: '对话',
    tabKnowledge: '记忆海',
    tabInbox: '进程',
    tabSettings: '设置',
    searchHint: '搜索文章、标签或笔记…',
    filterAll: '全部',
    manage: '管理',
    end: '末尾',
    add: '添加',
    noArticlesYet: '暂无文章',
    addFirstArticle: '添加你的第一篇文章，建立更有序的阅读队列。',
    homeDescription: '一站式保存来自 X、B站、小红书、ChatGPT、微信公众号及全网的文章。',
    noArticlesMatch: '没有文章匹配当前筛选条件',
    failedToLoad: '加载文章失败',
    alreadySaved: '已保存',
    savedProcessing: '已保存，后台处理中',
    processed: '已处理',
    failed: '失败',
    clipboardLink: '剪贴板链接',
    clipboardSave: '保存',
    addArticle: '添加文章',
    addMultipleUrls: '添加多个链接',
    save: '保存',
    supportedSources: '支持的来源',
    supportedSourcesDesc: '从已启用的平台粘贴链接，应用会自动识别来源。',
    titleOptional: '标题（可选）',
    fetchingTitle: '正在获取标题…',
    enterTitle: '输入文章标题',
    tags: '标签',
    typeAndPressEnter: '输入后按回车添加',
    notesOptional: '备注（可选）',
    addNotes: '添加关于此文章的备注',
    folderOptional: '文件夹（可选）',
    noFolder: '无文件夹',
    saveArticle: '保存文章',
    clipboardReadError: '无法读取剪贴板',
    bulkImportTitle: '添加多个链接',
    bulkImportDesc: '每行粘贴一个链接（或用空格/逗号分隔）。来源会自动识别。',
    addNUrls: '添加',
    addedNArticles: '已添加',
    articleDetails: '文章详情',
    back: '返回',
    removeFromFavorites: '取消收藏',
    addToFavorites: '添加收藏',
    delete: '删除',
    deleteArticle: '删除文章',
    deleteConfirm: '确定要删除此文章吗？此操作不可撤销。',
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
    summaryFailed: '摘要生成失败，请检查 AI 设置。',
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
    retry: '重试',
    deleteArticleQ: '删除文章？',
    removeFromInbox: '从进程移除？',
    inboxEmpty: '无处理中的文章',
    inboxEmptyDesc: '正在处理的文章会显示在此处。',
    configureAiFirst: '请先在设置中配置 AI。',
    knowledgeBaseEmpty: '记忆海为空。请先处理一些文章，然后再来提问。',
    notEnoughInfo: '在记忆海中找不到足够的相关信息来回答此问题。',
    emptyAiResponse: 'AI 服务返回了空响应，请重试。',
    aiError: '与 AI 服务通信出错',
    askKnowledgeBase: '向记忆海提问',
    tryExamples: '试试：「关于 AI 的核心观点是什么？」或「总结我保存的 Flutter 文章」',
    processFirst: '请先处理一些文章，然后再来提问。',
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
    deleteFolderConfirm: '删除此文件夹？文件夹中的文章将变为未归档。',
    noFoldersYet: '暂无文件夹',
    createFoldersDesc: '创建文件夹来整理文章',
    addSubfolder: '添加子文件夹',
    appearance: '外观',
    themeMode: '主题模式',
    system: '跟随系统',
    light: '浅色',
    dark: '深色',
    language: '语言',
    summaryStyle: '摘要样式',
    brief: '简洁',
    detailed: '详细',
    fontSizeSection: '字体大小',
    textSize: '文字大小',
    preview: '预览：敏捷的棕色狐狸跳过了懒狗。',
    reader: '阅读器',
    defaultWebZoom: '默认网页缩放',
    webZoomDesc: '控制在内置浏览器中打开文章时的初始缩放级别。',
    sourcePlatforms: '来源平台',
    reorderAndHide: '排序与隐藏',
    reorderDesc: '拖动以调整标签顺序。关闭不想在筛选中看到的平台。',
    visibleInFilters: '筛选中可见',
    hiddenFromFilters: '筛选中隐藏',
    preferences: '偏好',
    startupPage: '启动时打开',
    startupChat: '对话',
    startupKnowledge: '记忆海',
    settingsAccount: '账号',
    settingsAccountDesc: '使用统计、安全设置',
    accountTitle: '账号',
    usageDays: '已使用',
    memoryCount: '记忆数量',
    tokenConsumption: 'Token 消耗',
    accountSecurity: '账号安全',
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
    saveAiSettings: '保存 AI 设置',
    aiSettingsSaved: 'AI 设置已保存',
    settingsAppearance: '界面',
    settingsAppearanceDesc: '主题、语言、字体大小等',
    settingsOperations: '知识',
    settingsOperationsDesc: '批量处理、索引、剪贴板等',
    settingsOther: '其他',
    settingsOtherDesc: '来源平台、备份与恢复',
    settingsDev: '反馈统计',
    settingsDevDesc: '对话反馈数据（开发用）',
    fontWeight: '字体粗细',
    operations: '操作',
    knowledgeSectionLabel: '记忆管理',
    knowledgeBatchTitle: '补充生成摘要',
    knowledgeify: '批量知识化旧文章',
    knowledgeifyDesc: '为所有未生成摘要的文章生成摘要',
    processAll: '全部处理',
    batchProcessing: '批量处理',
    allProcessed: '所有文章已处理完毕。',
    nWithoutSummary: '篇文章没有摘要',
    configureAiFirstBtn: '请先配置 AI',
    nothingToProcess: '没有需要处理的',
    processNArticles: '处理篇文章',
    setupAiProvider: '请在上方设置 AI 以启用批量处理。',
    batchProcessConfirm: '处理篇文章？这将调用你的 AI 为每篇文章生成摘要和标签。',
    start: '开始',
    processedN: '已处理',
    embeddingSection: '嵌入与索引',
    embeddingConfig: '嵌入配置',
    defaultLabel: '默认',
    usingBuiltIn: '使用内置嵌入服务。你也可以使用自定义的 OpenAI 兼容端点。',
    usingCustom: '使用自定义 OpenAI 兼容嵌入端点。',
    embeddingBaseUrl: '嵌入基础 URL',
    embeddingApiKey: '嵌入 API 密钥',
    embeddingModel: '嵌入模型',
    testConnection: '测试连接',
    testing: '测试中…',
    connectionSuccessful: '连接成功',
    connectionFailed: '连接失败，请检查配置',
    resetToDefaults: '恢复默认',
    fillAllFields: '请先填写所有字段',
    indexManagement: '索引管理',
    nArticlesIndexed: '篇文章已索引',
    loadingIndexStatus: '加载索引状态…',
    rebuildIndex: '重建索引',
    rebuilding: '重建中…',
    indexedN: '已索引',
    configureEmbeddingFirst: '请先配置嵌入',
    data: '数据',
    backupRestore: '备份与恢复',
    backupDesc: '导出所有文章、筛选和设置到 JSON 文件，或导入备份。导入会合并到当前数据。',
    export: '导出',
    import: '导入',
    importBackup: '导入备份',
    importConfirm: '备份中的文章和筛选将合并到当前数据。应用设置将被替换。继续？',
    imported: '已导入',
    invalidBackup: '无效备份文件',
    exportFailed: '导出失败',
    importFailed: '导入失败',
    saveFailed: '保存失败',
    editFilter: '编辑筛选',
    newFilter: '新建筛选',
    filterName: '筛选名称',
    filterNameHint: '例如：「技术文章」「收藏」',
    pleaseEnterName: '请输入筛选名称',
    tagKeywords: '标签关键词',
    tagKeywordsDesc: '匹配任一标签的文章将被包含。',
    addTagKeyword: '添加标签关键词',
    sourcePlatformsFilter: '来源平台',
    sourcePlatformsDesc: '留空以包含所有来源，或选择特定来源。',
    manageFilters: '管理筛选',
    newButton: '新建',
    noCustomFilters: '暂无自定义筛选',
    allArticles: '所有文章',
    urlLabel: '链接',
    urlHint: 'https://x.com/... 或 https://www.bilibili.com/...',
    pasteFromClipboard: '从剪贴板粘贴',
    pleaseEnterUrl: '请输入链接',
    pleaseEnterValidUrl: '请输入有效链接',
    detected: '已识别',
  );
}
