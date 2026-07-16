我最推荐你的方案：三级结构
=============

对于 Memora，我会设计成：

### Level 1：Article Summary Vector

    {  "type": "article",  "article_id": "123",  "text": "标题 + 摘要 + 总结",  "embedding": [...]}

负责：

> 用户大概在问哪篇文章？

* * *

### Level 2：Key Point Vector

    {  "type": "point",  "article_id": "123",  "point_id": "123_3",  "text": "标题 + 当前要点 + 少量上下文",  "embedding": [...]}

负责：

> 用户具体在问文章里的哪个知识点？

* * *

### Level 3：原始内容

真正回答时拿：
    标题摘要命中的要点相邻要点总结原文片段（如果存在）

送给 LLM。

因此你的检索过程变成：
    Query  ↓Article Retrieval  ↓候选 Article IDs  ↓Point Retrieval within candidates  ↓Context Expansion  ↓LLM Answer

这就是典型的 **hierarchical retrieval / parent-child retrieval** 思路。
