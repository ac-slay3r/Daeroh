import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

final class MissionControlCopy {
  final Strings _strings;

  const MissionControlCopy._(this._strings);

  factory MissionControlCopy.of(BuildContext context) =>
      MissionControlCopy._(Strings.of(context));

  String get title => _strings.missionTitle;
  String get allAgents => _strings.missionCopyAllAgents;
  String get chooseWorkspace => _strings.missionCopyChooseWorkspace;
  String get workspaces => _strings.missionCopyWorkspaces;
  String workspaceAgentCount(int count) =>
      _strings.missionCopyWorkspaceAgentCount(count);
  String get createOrganization => _strings.missionCopyCreateOrganization;
  String get editOrganization => _strings.missionCopyEditOrganization;
  String get organizationName => _strings.missionCopyOrganizationName;
  String get organizationHint => _strings.missionCopyOrganizationHint;
  String get chooseProfiles => _strings.missionCopyChooseProfiles;
  String get save => _strings.missionHostedSave;
  String get cancel => _strings.missionHostedCancel;
  String get delete => _strings.missionCopyDelete;
  String get deleteOrganizationTitle =>
      _strings.missionCopyDeleteOrganizationTitle;
  String get deleteOrganizationBody =>
      _strings.missionCopyDeleteOrganizationBody;
  String get loading => _strings.missionCopyLoading;
  String get retry => _strings.missionCopyRetry;
  String get refresh => _strings.missionCopyRefresh;
  String get overview => _strings.missionCopyOverview;
  String get tasks => _strings.missionCopyTasks;
  String assignedTasks(int count) => _strings.missionCopyAssignedTasks(count);
  String get activity => _strings.missionCopyActivity;
  String get recentActivity => _strings.missionCopyRecentActivity;
  String get showAllActivity => _strings.missionCopyShowAllActivity;
  String get showLess => _strings.missionCopyShowLess;
  String get bots => _strings.missionBotsLabel;
  String botCount(int count) => _strings.missionCopyBotCount(count);
  String get sharedRoomName => _strings.missionCopySharedRoomName;
  String get chooseSharedMembers => _strings.missionCopyChooseSharedMembers;
  String get viewMembers => _strings.missionCopyViewMembers;
  String get roomConversation => _strings.missionCopyRoomConversation;
  String get replyInThread => _strings.missionCopyReplyInThread;
  String get noRoomMessages => _strings.missionCopyNoRoomMessages;

  /// Estado del composer cuando hay un hilo elegido con "Responder en hilo".
  /// Antes el único indicio era que el texto de sugerencia del campo cambiaba,
  /// y no había forma de salir del hilo salvo enviar el mensaje.
  String get replyingInThread => _strings.missionCopyReplyingInThread;
  String get stopReplyingInThread => _strings.missionCopyStopReplyingInThread;

  /// El protocolo real de una sala compartida (`groups.send`) solo acepta
  /// `text` y `thread_id`: no hay campo de adjunto ni de imagen en ninguna
  /// versión del evento. En vez de poner un botón que no puede funcionar, la
  /// sala vacía lo dice una vez, en voz baja.
  String get roomTextOnly => _strings.missionCopyRoomTextOnly;
  String get sharedRooms => _strings.missionSharedRooms;
  String get createSharedRoom => _strings.missionCreateSharedRoom;
  String get noSharedRooms => _strings.missionNoSharedRooms;
  String get sharedRoomsUnavailable => _strings.missionSharedRoomsUnavailable;
  String get roomDriverUnavailable => _strings.missionCopyRoomDriverUnavailable;
  String get roomRefreshFailed => _strings.missionCopyRoomRefreshFailed;
  String get sendSharedMessage => _strings.missionSendSharedMessage;
  String get renameSharedRoom => _strings.missionRenameSharedRoom;
  // "¿Detener/Disolver la sala compartida?" es el título del diálogo de
  // confirmación (pregunta, tiene sentido ahí) — reutilizado tal cual como
  // etiqueta del ítem del menú de los "..." leía como una pregunta suelta,
  // inconsistente con "Renombrar sala compartida" justo al lado (confirmado
  // en dispositivo real). Los *Action de abajo son la forma imperativa,
  // solo para las filas del menú; los diálogos de confirmación siguen
  // usando `stopSharedRoom`/`disbandSharedRoom` tal cual.
  String get stopSharedRoom => _strings.missionStopSharedRoom;
  String get disbandSharedRoom => _strings.missionDisbandSharedRoom;
  String get stopSharedRoomAction => _strings.missionStopSharedRoomAction;
  String get disbandSharedRoomAction => _strings.missionDisbandSharedRoomAction;
  String get confirm => _strings.missionConfirm;
  String get hostedActionFailed => _strings.missionHostedActionFailed;
  String get retrySharedTaskAvailable => _strings.missionHostedRetryAvailable;
  String get retrySharedTask => _strings.missionHostedRetryAction;
  String get retrySharedTaskConfirm => _strings.missionHostedRetryConfirm;
  String sharedRoomSemantics(String name, int members) =>
      _strings.missionSharedRoomSemantics(name, members);

  String get addToMissionControl => _strings.missionCopyAddToMissionControl;
  String get createAgent => _strings.missionCopyCreateAgent;
  String get createAgentDescription =>
      _strings.missionCopyCreateAgentDescription;
  String get newAgent => _strings.missionCopyNewAgent;
  String get botChat => 'Bot Chat';
  String get botDetails => _strings.missionCopyBotDetails;
  String get noBots => _strings.missionCopyNoBots;
  String get botNeedsYou => _strings.missionCopyBotNeedsYou;
  String get searchAgents => _strings.missionCopySearchAgents;
  String get clearSearch => _strings.missionCopyClearSearch;
  String get activeNow => _strings.missionCopyActiveNow;
  String get pinnedBots => _strings.missionCopyPinnedBots;
  String get otherBots => _strings.missionCopyOtherBots;
  String get allBots => _strings.missionCopyAllBots;
  String get searchResults => _strings.missionCopySearchResults;
  String showHiddenBots(int count) => _strings.missionCopyShowHiddenBots(count);
  String get hideHiddenBots => _strings.missionCopyHideHiddenBots;
  String get pinBot => _strings.missionCopyPinBot;
  String get unpinBot => _strings.missionCopyUnpinBot;
  String get hideBot => _strings.missionCopyHideBot;
  String get showBot => _strings.missionCopyShowBot;
  String get botRosterUpdateFailed => _strings.missionCopyBotRosterUpdateFailed;
  String get noMatchingAgents => _strings.missionCopyNoMatchingAgents;
  String get roomTeam => _strings.missionCopyRoomTeam;
  String roomMemberCount(int count) => _strings.missionHostedMemberCount(count);
  String roomHomeSummary(int agents, int rooms) =>
      _strings.missionCopyRoomHomeSummary(agents, rooms);
  String roomCount(int count) => _strings.missionHostedRoomCount(count);
  String attentionSummary(int approvals, int blocked) =>
      _strings.missionCopyAttentionSummary(approvals, blocked);
  String get needsYou => _strings.missionCopyNeedsYou;
  String get usage => _strings.missionCopyUsage;
  String get profilesUnavailable => _strings.missionCopyProfilesUnavailable;
  String get roomsBrowseOnly => _strings.missionCopyRoomsBrowseOnly;
  String get offline => _strings.missionOffline;
  String get staleData => _strings.missionStaleData;
  String get noProfiles => _strings.missionCopyNoProfiles;
  String get noTasks => _strings.missionCopyNoTasks;
  String get kanbanUnavailable => _strings.missionKanbanUnavailable;
  String get noActivity => _strings.missionCopyNoActivity;
  String get noApprovals => _strings.missionCopyNoApprovals;
  String get openChat => _strings.missionCopyOpenChat;
  String get review => _strings.missionCopyReview;
  String get openKanban => _strings.missionCopyOpenKanban;
  String get manageProfiles => _strings.missionCopyManageProfiles;
  String get editProfile => _strings.missionCopyEditProfile;
  String get routines => _strings.missionCopyRoutines;
  String get memory => _strings.missionCopyMemory;
  String get skills => 'Skills';
  String get soul => 'SOUL';
  String get recentSessions => _strings.missionCopyRecentSessions;
  String get modelUnavailable => _strings.missionCopyModelUnavailable;
  String get costUnavailable => _strings.missionCopyCostUnavailable;
  String get partialCost => _strings.missionCopyPartialCost;
  String get staleProfiles => _strings.missionCopyStaleProfiles;
  String unattributedSessions(int count) =>
      _strings.missionCopyUnattributedSessions(count);
  String get working => _strings.missionCopyWorking;
  String get approvals => _strings.missionCopyApprovals;
  String get blocked => _strings.missionCopyBlocked;
  String get tokens => _strings.missionCopyTokens;
  String get input => 'input';
  String get output => 'output';
  String get cached => _strings.missionCopyCached;
  String get reasoning => 'reasoning';
  String get unknown => _strings.missionCopyUnknown;
  String get profileLabel => 'Profile';
  String get modelLabel => _strings.missionCopyModelLabel;
  String get managerLabel => 'Manager';
  String get tokensUnavailable => _strings.missionCopyTokensUnavailable;

  // Editor del bot (identidad visible del profile: nombre, cara y sprite).
  String get editBotTitle => _strings.missionCopyEditBotTitle;
  String get botDisplayName => _strings.missionCopyBotDisplayName;
  String get botDisplayNameHint => _strings.missionCopyBotDisplayNameHint;
  String get botShapeLabel => _strings.missionCopyBotShapeLabel;
  String get botColorLabel => _strings.missionCopyBotColorLabel;
  String get botFaceFallbackHint => _strings.missionCopyBotFaceFallbackHint;
  String get botSpriteLabel => 'Sprite';
  String get botSpriteHint => _strings.missionCopyBotSpriteHint;
  String get botSpriteNone => _strings.missionCopyBotSpriteNone;
  String get botSpriteSearchHint => _strings.missionCopyBotSpriteSearchHint;
  String get botSpriteEmpty => _strings.missionCopyBotSpriteEmpty;
  String get botSpriteUnsupported => _strings.missionCopyBotSpriteUnsupported;
  String get botEditorSaved => _strings.missionCopyBotEditorSaved;
  String get botEditorSaveFailed => _strings.missionCopyBotEditorSaveFailed;

  // Creación de bots (paridad con CreateAgentDialog de Hermes Desktop).
  String get createAgentSubtitle => _strings.missionCopyCreateAgentSubtitle;
  String get agentNameLabel => _strings.missionCopyAgentNameLabel;
  String get agentNameHint => 'inbox-triage';
  String get agentNameInvalid => _strings.missionCopyAgentNameInvalid;
  String get agentNameTaken => _strings.missionCopyAgentNameTaken;
  String get agentTitleLabel => _strings.missionCopyAgentTitleLabel;
  String get agentTitleHint => 'Inbox Triage';
  String get agentDescriptionLabel => _strings.missionCopyAgentDescriptionLabel;
  String get agentDescriptionHint => _strings.missionCopyAgentDescriptionHint;
  String get modelInherited => _strings.missionCopyModelInherited;
  String get modelPickerTitle => _strings.missionCopyModelPickerTitle;
  String get modelCatalogEmpty => _strings.missionCopyModelCatalogEmpty;
  String get providerLabel => _strings.missionCopyProviderLabel;
  String get advanced => _strings.missionCopyAdvanced;
  String get cloneFromLabel => _strings.missionCopyCloneFromLabel;
  String get cloneFresh => _strings.missionCopyCloneFresh;
  String get shareAuthLabel => _strings.missionCopyShareAuthLabel;
  String get shareAuthHint => _strings.missionCopyShareAuthHint;
  String get noSkillsLabel => _strings.missionCopyNoSkillsLabel;
  String get soulOptionalLabel => _strings.missionCopySoulOptionalLabel;
  String get soulOptionalHint => _strings.missionCopySoulOptionalHint;
  String get skillsLoading => _strings.missionCopySkillsLoading;
  String get skillsUnavailable => _strings.missionCopySkillsUnavailable;
  String skillsFromSource(String source) =>
      _strings.missionCopySkillsFromSource(source);
  String get createAgentSubmit => _strings.missionCopyCreateAgentSubmit;
  String createAgentError(String detail) =>
      _strings.missionCopyCreateAgentError(detail);
  String agentCreated(String name) => _strings.missionCopyAgentCreated(name);

  String status(String value) => switch (value) {
    'idle' => _strings.missionCopyStatusIdle,
    'thinking' => _strings.missionCopyStatusThinking,
    'working' => _strings.missionCopyStatusWorking,
    'responding' => _strings.missionCopyStatusResponding,
    'blocked' => _strings.missionCopyStatusBlocked,
    'approvalRequired' => _strings.missionCopyStatusApprovalRequired,
    'error' => 'Error',
    _ => unknown,
  };

  String activityLabel(String value) => switch (value) {
    'sessionUpdated' => _strings.missionCopyActivityLabelSessionUpdated,
    'taskCreated' => _strings.missionCopyActivityLabelTaskCreated,
    'taskStarted' => _strings.missionCopyActivityLabelTaskStarted,
    'taskCompleted' => _strings.missionCopyActivityLabelTaskCompleted,
    'taskBlocked' => _strings.missionCopyActivityLabelTaskBlocked,
    _ => value,
  };

  String taskStatus(String value) => switch (value) {
    'ready' => _strings.missionCopyTaskStatusReady,
    'running' => _strings.missionCopyTaskStatusRunning,
    'blocked' => _strings.missionCopyTaskStatusBlocked,
    'review' => _strings.missionCopyTaskStatusReview,
    'done' => _strings.missionCopyTaskStatusDone,
    'scheduled' => _strings.missionCopyTaskStatusScheduled,
    'todo' => _strings.missionCopyTaskStatusTodo,
    'triage' => _strings.missionCopyTaskStatusTriage,
    _ => value,
  };
}
