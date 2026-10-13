## Vectors

Currently, the weighted map is assmbled and links are determined by adjacency; however, if two cells happen to be adjacent and weighted, they will form a link even if they do not have a path between them. To fix, we will need to 

* Remember each villager's cell from the previous sample.
* When they move to a neighbouring cell, add weight to the link between those two cells. The search would then only follow links someone actually walked.
* Costs:
  * Storage and save size would grow about 2–4 times, since each cell can have up to four links.
  * Links would need the same fading and cleanup as cells.
  * The knight steps that keep distances accurate would have to be rebuilt from pairs of links.
