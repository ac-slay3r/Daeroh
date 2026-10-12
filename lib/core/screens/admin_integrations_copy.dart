import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

/// Copy ES/EN tipada de la superficie de integraciones 0.20.
///
/// No se decide por región ni por dispositivo: sigue el locale efectivo de la
/// aplicación igual que el resto de superficies localizadas.
final class AdminIntegrationsCopy {
  final Strings _strings;

  const AdminIntegrationsCopy._(this._strings);

  factory AdminIntegrationsCopy.of(BuildContext context) =>
      AdminIntegrationsCopy._(Strings.of(context));

  String get screenTitle => _strings.adminIntegrationScreenTitle;
  String get entryTitle => _strings.adminIntegrationEntryTitle;
  String get entryBody => _strings.adminIntegrationEntryBody;
  String get sectionLabel => _strings.adminIntegrationSectionLabel;
  String get mcpTab => 'MCP';
  String get webhooksTab => 'Webhooks';
  String get serverTab => _strings.adminIntegrationServerTab;
  String get readOnly => _strings.adminIntegrationReadOnly;
  String get refresh => _strings.adminIntegrationRefresh;
  String get retry => _strings.adminIntegrationRetry;
  String get cancel => _strings.adminIntegrationCancel;
  String get close => _strings.adminIntegrationClose;
  String get done => _strings.adminIntegrationDone;
  String get copy => _strings.adminIntegrationCopy;
  String get copied => _strings.adminIntegrationCopied;
  String get delete => _strings.adminIntegrationDelete;
  String get moreOptions => _strings.adminIntegrationMoreOptions;

  String get mcpIntro => _strings.adminIntegrationMcpIntro;
  String get addMcp => _strings.adminIntegrationAddMcp;
  String get addMcpBody => _strings.adminIntegrationAddMcpBody;
  String get noMcpPut => _strings.adminIntegrationNoMcpPut;
  String get manualMcpUnavailable =>
      _strings.adminIntegrationManualMcpUnavailable;
  String get mcpFormTitle => _strings.adminIntegrationMcpFormTitle;
  String get transport => _strings.adminIntegrationTransport;
  String get stdio => _strings.adminIntegrationStdio;
  String get http => 'HTTP';
  String get name => _strings.adminIntegrationName;
  String get nameHint => _strings.adminIntegrationNameHint;
  String get command => _strings.adminIntegrationCommand;
  String get commandHint => _strings.adminIntegrationCommandHint;
  String get arguments => _strings.adminIntegrationArguments;
  String get argumentsHint => _strings.adminIntegrationArgumentsHint;
  String get environment => _strings.adminIntegrationEnvironment;
  String get environmentHint => _strings.adminIntegrationEnvironmentHint;
  String get variableName => _strings.adminIntegrationVariableName;
  String get variableValue => _strings.adminIntegrationVariableValue;
  String get addVariable => _strings.adminIntegrationAddVariable;
  String get removeVariable => _strings.adminIntegrationRemoveVariable;
  String get endpointUrl => _strings.adminIntegrationEndpointUrl;
  String get endpointHint => _strings.adminIntegrationEndpointHint;
  String get authentication => _strings.adminIntegrationAuthentication;
  String get authNone => _strings.adminIntegrationAuthNone;
  String get authHeader => _strings.adminIntegrationAuthHeader;
  String get authOauth => _strings.adminIntegrationAuthOauth;
  String get bearerToken => _strings.adminIntegrationBearerToken;
  String get bearerHint => _strings.adminIntegrationBearerHint;
  String get createMcp => _strings.adminIntegrationCreateMcp;
  String get mcpCreated => _strings.adminIntegrationMcpCreated;
  String get invalidForm => _strings.adminIntegrationInvalidForm;
  String get incompleteEnvironment =>
      _strings.adminIntegrationIncompleteEnvironment;
  String get authorize => _strings.adminIntegrationAuthorize;

  String get oauthTitle => _strings.adminIntegrationOauthTitle;
  String get oauthBody => _strings.adminIntegrationOauthBody;
  String get openBrowser => _strings.adminIntegrationOpenBrowser;
  String get openingBrowserFailed =>
      _strings.adminIntegrationOpeningBrowserFailed;
  String get oauthWaiting => _strings.adminIntegrationOauthWaiting;
  String get oauthApproved => _strings.adminIntegrationOauthApproved;
  String get oauthError => _strings.adminIntegrationOauthError;
  String get oauthExpired => _strings.adminIntegrationOauthExpired;
  String get oauthUnknown => _strings.adminIntegrationOauthUnknown;
  String oauthTools(int count) => _strings.adminIntegrationOauthTools(count);

  String get webhooksIntro => _strings.adminIntegrationWebhooksIntro;
  String get webhooksUnavailable =>
      _strings.adminIntegrationWebhooksUnavailable;
  String get webhookLoadFailed => _strings.adminIntegrationWebhookLoadFailed;
  String get webhooksDisabled => _strings.adminIntegrationWebhooksDisabled;
  String get webhooksDisabledBody =>
      _strings.adminIntegrationWebhooksDisabledBody;
  String get enableWebhooks => _strings.adminIntegrationEnableWebhooks;
  String get enableWarningTitle => _strings.adminIntegrationEnableWarningTitle;
  String get enableWarningBody => _strings.adminIntegrationEnableWarningBody;
  String get enable => _strings.adminIntegrationEnable;
  String get disable => _strings.adminIntegrationDisable;
  String get webhooksEnabledRestarting =>
      _strings.adminIntegrationWebhooksEnabledRestarting;
  String get webhooksEnabled => _strings.adminIntegrationWebhooksEnabled;
  String get webhooksNeedRestart =>
      _strings.adminIntegrationWebhooksNeedRestart;
  String get addWebhook => _strings.adminIntegrationAddWebhook;
  String get addWebhookBody => _strings.adminIntegrationAddWebhookBody;
  String get noWebhooks => _strings.adminIntegrationNoWebhooks;
  String get webhookFormTitle => _strings.adminIntegrationWebhookFormTitle;
  String get description => _strings.adminIntegrationDescription;
  String get descriptionHint => _strings.adminIntegrationDescriptionHint;
  String get prompt => _strings.adminIntegrationPrompt;
  String get promptHint => _strings.adminIntegrationPromptHint;
  String get events => _strings.adminIntegrationEvents;
  String get eventsHint => _strings.adminIntegrationEventsHint;
  String get skills => _strings.adminIntegrationSkills;
  String get skillsHint => _strings.adminIntegrationSkillsHint;
  String get delivery => _strings.adminIntegrationDelivery;
  String get deliverOnly => _strings.adminIntegrationDeliverOnly;
  String get deliverOnlyHint => _strings.adminIntegrationDeliverOnlyHint;
  String deliveryLabel(String value) => switch (value) {
    'log' => _strings.adminIntegrationDeliveryLabelLog,
    'telegram' => 'Telegram',
    'discord' => 'Discord',
    'slack' => 'Slack',
    'email' => _strings.adminIntegrationDeliveryLabelEmail,
    'github_comment' => _strings.adminIntegrationDeliveryLabelGithubComment,
    _ => value,
  };
  String get createWebhook => _strings.adminIntegrationCreateWebhook;
  String get webhookCreated => _strings.adminIntegrationWebhookCreated;
  String get duplicateWebhook => _strings.adminIntegrationDuplicateWebhook;
  String get secretTitle => _strings.adminIntegrationSecretTitle;
  String get secretBody => _strings.adminIntegrationSecretBody;
  String get webhookUrl => _strings.adminIntegrationWebhookUrl;
  String get webhookSecret => _strings.adminIntegrationWebhookSecret;
  String get deleteWebhookTitle => _strings.adminIntegrationDeleteWebhookTitle;
  String get deleteWebhookBody => _strings.adminIntegrationDeleteWebhookBody;
  String get webhookDeleted => _strings.adminIntegrationWebhookDeleted;
  String webhookSubtitle(String deliver, List<String> events) {
    final eventText = events.isEmpty
        ? (_strings.adminIntegrationAllEvents)
        : events.join(', ');
    return '${deliveryLabel(deliver)} · $eventText';
  }

  String get a2aIntro => _strings.adminIntegrationA2aIntro;
  String get a2aUnavailable => _strings.adminIntegrationA2aUnavailable;
  String get a2aNotPublished => _strings.adminIntegrationA2aNotPublished;
  String get a2aTitle => 'A2A';
  String get configured => _strings.adminIntegrationConfigured;
  String get notConfigured => _strings.adminIntegrationNotConfigured;
  String get running => _strings.adminIntegrationRunning;
  String get stopped => _strings.adminIntegrationStopped;
  String get active => _strings.adminIntegrationActive;
  String get inactive => _strings.adminIntegrationInactive;
  String a2aState(String state) => switch (state) {
    'connected' => _strings.adminIntegrationA2aStateConnected,
    'connecting' => _strings.adminIntegrationA2aStateConnecting,
    'retrying' => _strings.adminIntegrationA2aStateRetrying,
    'pending_restart' => _strings.adminIntegrationA2aStatePendingRestart,
    'not_configured' => _strings.adminIntegrationA2aStateNotConfigured,
    'gateway_stopped' => _strings.adminIntegrationA2aStateGatewayStopped,
    'startup_failed' => _strings.adminIntegrationA2aStateStartupFailed,
    'disconnected' => _strings.adminIntegrationA2aStateDisconnected,
    'fatal' => _strings.adminIntegrationA2aStateFatal,
    'disabled' => _strings.adminIntegrationA2aStateDisabled,
    _ => _strings.adminIntegrationA2aStateFallback,
  };

  String get unsupported => _strings.adminIntegrationUnsupported;
  String get forbidden => _strings.adminIntegrationForbidden;
  String get unavailable => _strings.adminIntegrationUnavailable;
  String get invalidResponse => _strings.adminIntegrationInvalidResponse;
  String get rejected => _strings.adminIntegrationRejected;
}
