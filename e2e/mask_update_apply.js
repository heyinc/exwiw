const fs = require("fs");

const lines = fs.readFileSync(process.env.MASK_UPDATE_FILE, "utf8").split("\n").filter(Boolean);
for (const line of lines) {
  const [name, operations] = EJSON.parse(line, { relaxed: false });
  db.getCollection(name).bulkWrite(operations);
}
