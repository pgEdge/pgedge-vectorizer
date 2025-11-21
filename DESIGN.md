# pgEdge Vectorizer

pgEdge Vectorizer is a PostgreSQL Extension written in C and SQL. At a high
level, it allows a user to configure one or more tables containing one or more 
text columns for chunking and vectorization.

A SQL function is used to setup a table in the system. This will create a 
chunk table for each configured column, with a foreign key reference. The 
chunk tables will later hold one or more rows for every row in the source 
table, containing chunks of the source column text and a vector embedding 
representing the text. A trigger will also be created on the source table to
record the details of the update or insert in a queue table, and send a NOTIFY 
message to inform a background worker that there is work to do.

The background worker will run under PostgreSQL's normal infrastructure,
restarting if needed after a crash. It will connect to one or more of the
databases on the server, and listen for the NOTIFY messages sent by the
trigger. On receipt of a notification it will query the queue table for
information on what table, row, and column(s) have changed, and read the
required data. It will chunk the data and generate vector embeddings using
a configured model via Ollama, OpenAI, or Voyage AI, with API keys stored
in a dedicated file outside of the data directory on the PostgreSQL server,
pointed to by a GUC variable. All other LLM configuration will be stored
directly in GUCs. Once the data is chuncked and embeddings generated, they
will be inserted or updated in the appropriate chunk table for use by the
user.

For more information see BRAINSTORMING.md in the root of the project,
which should be taken not as a full design, but as a set of ideas for 
implementing the extension.

pgEdge Vectorise should support PostgreSQL 14 and later, with the pgVector
extension.