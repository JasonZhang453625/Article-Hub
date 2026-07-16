# RAG Conversation Quality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the five known RAG conversation gaps: history-aware retrieval, token-budgeted evidence selection, local reranking, strict citation display, and UI-independent orchestration.

**Architecture:** Keep the current Hive index, hybrid vector/keyword retrieval, RRF, and citation validator. Add a pure local evidence reranker/context budgeter and a `RagConversationService` that owns query rewrite, retrieval, prompt assembly, answer generation, citation validation, and retrieval logging; `ChatScreen` becomes a UI adapter only.

**Tech Stack:** Flutter/Dart, Riverpod, existing OpenAI-compatible `AiService`, Hive retrieval logs, pure Dart unit tests.

## Global Constraints

- Do not add LangChain or a hosted reranker dependency.
- Query rewriting may call the configured chat model only when prior conversation exists; failure must fall back to the original question.
- Reranking and context selection must remain local and deterministic.
- Only model-emitted, validated citation IDs may be displayed.
- Preserve existing knowledge-only versus hybrid/general-knowledge behavior.
- Do not commit or stage changes unless the user explicitly requests it.

---

### Task 1: Local evidence reranking and token-budgeted context

**Files:**
- Create: `lib/data/services/rag_context_builder.dart`
- Test: `test/rag_context_builder_test.dart`

**Interfaces:**
- Produces: `RagEvidenceReranker.rerank(String, List<Article>)`
- Produces: `RagContextBuilder.build({required String query, required List<Article> candidates, int tokenBudget})`
- Produces: `RagContextPackage` containing rendered context, selected articles, citation map, and estimated token count.

- [ ] **Step 1: Write failing reranking tests**

```dart
final ranked = const RagEvidenceReranker().rerank('handoff mechanism', [unrelated, matching]);
expect(ranked.first.article.id, matching.id);
```

- [ ] **Step 2: Run tests and confirm missing implementation failure**

Run: `flutter test test/rag_context_builder_test.dart`

- [ ] **Step 3: Implement evidence extraction and deterministic scoring**

Use structured overview/key points/conclusion when available; split legacy/full-text bodies into bounded evidence units. Weight title and tags above body overlap and preserve original retrieval order as a tie-breaker.

- [ ] **Step 4: Implement token-budgeted packing**

Select the best evidence from each reranked article first, then fill remaining budget with additional high-scoring evidence. Build citation numbers only for articles actually included in the context.

- [ ] **Step 5: Verify tests pass**

Run: `flutter test test/rag_context_builder_test.dart`

### Task 2: History-aware query rewriting and conversation orchestration

**Files:**
- Create: `lib/data/services/rag_conversation_service.dart`
- Create: `assets/prompts/chat/query_rewrite.txt`
- Modify: `lib/data/services/retrieval_log_service.dart`
- Test: `test/rag_conversation_service_test.dart`
- Test: `test/retrieval_log_test.dart`

**Interfaces:**
- Produces: `RagConversationRequest`, `RagConversationTurn`, `RagConversationResult`, and `RagConversationOutcome`.
- Consumes: retrieval, completion, and log-save callbacks so the service is testable without Hive or network calls.
- Produces: `HistoryAwareQueryRewriter.rewrite(...)`, falling back to the original query on empty/error output.

- [ ] **Step 1: Write failing query rewrite tests**

```dart
final rewritten = await rewriter.rewrite(
  question: '第二点有什么缺陷？',
  history: const [RagConversationTurn(role: 'user', content: '解释 Agent handoff 机制')],
);
expect(rewritten, contains('handoff'));
```

- [ ] **Step 2: Write failing orchestration and strict citation tests**

Assert that retrieval receives the rewritten query, the answer model receives token-budgeted context, and a response without `[n]` returns an empty cited-ID list rather than all candidates.

- [ ] **Step 3: Run tests and confirm expected failures**

Run: `flutter test test/rag_conversation_service_test.dart test/retrieval_log_test.dart`

- [ ] **Step 4: Implement query rewrite and orchestration**

Sequence: rewrite with history -> hybrid retrieve -> local rerank/context pack -> prompt selection -> final model call -> citation validation -> local retrieval log. Keep the original question for the final answer prompt and the rewritten query only for retrieval.

- [ ] **Step 5: Add optional rewritten query to local logs**

`RetrievalLog.fromMap` must accept old records without the new field.

- [ ] **Step 6: Verify tests pass**

Run: `flutter test test/rag_conversation_service_test.dart test/retrieval_log_test.dart`

### Task 3: Make ChatScreen a UI adapter

**Files:**
- Modify: `lib/features/chat/chat_screen.dart`
- Modify: `lib/shared/providers/ai_providers.dart`
- Test: `test/chat_screen_widget_test.dart`

**Interfaces:**
- Consumes: `RagConversationService.ask(RagConversationRequest)`.
- UI remains responsible only for collecting state, showing loading/results, navigation, and localized user-facing error/no-result copy.

- [ ] **Step 1: Add source-level/widget assertions for the extracted flow**

Verify the screen maps answer IDs directly from validated `citedIds` and does not contain fixed `maxContextPerArticle` truncation or candidate fallback logic.

- [ ] **Step 2: Run tests and confirm failure against current screen**

Run: `flutter test test/rag_conversation_service_test.dart test/chat_screen_widget_test.dart`

- [ ] **Step 3: Replace inline orchestration with service invocation**

Capture history before appending the new user message, construct the configured `AiService`, invoke `RagConversationService`, and map its outcome to `ChatMessage`.

- [ ] **Step 4: Retrieve a wider candidate pool for local reranking**

Configure the production retriever with `topK: 10`; the context builder limits final context to five articles.

- [ ] **Step 5: Verify focused and regression tests**

Run: `flutter test test/rag_context_builder_test.dart test/rag_conversation_service_test.dart test/rag_citation_test.dart test/retrieval_log_test.dart test/embedding_retrieval_test.dart test/retrieval_query_set_test.dart`

### Task 4: Final verification

**Files:**
- Review all files above.

- [ ] **Step 1: Format edited Dart files**

Run: `dart format <edited Dart files>`

- [ ] **Step 2: Run broad tests**

Run all non-stale tests, excluding only the three already-known stale UI-copy suites if they still fail solely on existing product copy.

- [ ] **Step 3: Run static and diff checks**

Run: `flutter analyze`

Run: `git diff --check`

- [ ] **Step 4: Review requirement coverage**

Confirm all five requirements have direct tests and that no API key, article body, or unrelated workspace change was added to source control.
