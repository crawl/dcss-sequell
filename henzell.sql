DROP TABLE IF EXISTS logrecord;
DROP TABLE IF EXISTS spr_logrecord;
DROP TABLE IF EXISTS zot_logrecord;
DROP TABLE IF EXISTS logfiles;
DROP TABLE IF EXISTS milestone;
DROP TABLE IF EXISTS spr_milestone;
DROP TABLE IF EXISTS zot_milestone;
DROP TABLE IF EXISTS milestone_files;

CREATE TABLE logfiles (
    file VARCHAR(150) PRIMARY KEY
);

CREATE TABLE milestone_files (
    file VARCHAR(150) PRIMARY KEY
);

CREATE TABLE logrecord (
    id BIGINT AUTO_INCREMENT,
    offset BIGINT,
    file VARCHAR(150),
    -- 'y' for alpha, anything else otherwise.
    alpha CHAR(1),
    src CHAR(5),
    v VARCHAR(10),
    cv VARCHAR(10),
    lv VARCHAR(8),
    sc BIGINT,
    pname VARCHAR(20),
    uid INT,
    race VARCHAR(20),
    crace VARCHAR(20),
    cls VARCHAR(20),
    charabbrev CHAR(4),
    xl INT,
    sk VARCHAR(16),
    sklev INT,
    title VARCHAR(50),
    ktyp VARCHAR(20),
    killer VARCHAR(50),
    ckiller VARCHAR(50),
    ikiller VARCHAR(50),
    kpath VARCHAR(255),
    kmod VARCHAR(50),
    kaux VARCHAR(255),
    ckaux VARCHAR(255),
    place VARCHAR(16),
    mapname VARCHAR(80),
    mapdesc VARCHAR(80),
    br VARCHAR(16),
    lvl INT,
    ltyp VARCHAR(16),
    hp INT,
    mhp INT,
    mmhp INT,
    dam INT,
    sstr INT,
    sint INT,
    sdex INT,
    god VARCHAR(50),
    piety INT,
    pen INT,
    wiz INT,
    tstart DATETIME,
    tend DATETIME,
    rstart CHAR(15),
    rend CHAR(15),
    dur BIGINT,
    turn BIGINT,
    urune INT,
    nrune INT,
    tmsg VARCHAR(255),
    vmsg VARCHAR(255),
    splat CHAR(1),
    tiles CHAR(1),

    -- How many times it's been played on FooTV
    ntv INT DEFAULT 0,
    
    PRIMARY KEY (id)
);
CREATE INDEX ind_foffset ON logrecord (file, offset);
CREATE INDEX ind_milelocate ON logrecord (src, pname, rstart);

CREATE TABLE spr_logrecord AS
SELECT * FROM logrecord LIMIT 1;
TRUNCATE TABLE spr_logrecord;
ALTER TABLE spr_logrecord ADD PRIMARY KEY (id);
ALTER TABLE spr_logrecord CHANGE COLUMN id id BIGINT AUTO_INCREMENT;
CREATE INDEX spr_ind_foffset ON spr_logrecord (file, offset);
CREATE INDEX spr_ind_milelocate ON spr_logrecord (src, pname, rstart);

CREATE TABLE zot_logrecord AS
SELECT * FROM logrecord LIMIT 1;
TRUNCATE TABLE zot_logrecord;
ALTER TABLE zot_logrecord ADD PRIMARY KEY (id);
ALTER TABLE zot_logrecord CHANGE COLUMN id id BIGINT AUTO_INCREMENT;
CREATE INDEX zot_ind_foffset ON zot_logrecord (file, offset);
CREATE INDEX zot_ind_milelocate ON zot_logrecord (src, pname, rstart);

CREATE TABLE milestone (
    id BIGINT AUTO_INCREMENT,
    offset BIGINT,
    file VARCHAR(150),
    alpha CHAR(1),
    tiles CHAR(1),
    src CHAR(5),

    -- The actual game that this milestone is linked with.
    game_id BIGINT,

    v VARCHAR(10),
    cv VARCHAR(10),
    pname VARCHAR(20),
    race VARCHAR(20),
    crace VARCHAR(20),
    cls VARCHAR(20),
    charabbrev CHAR(4),
    xl INT,
    sk VARCHAR(16),
    sklev INT,
    title VARCHAR(50),
    place VARCHAR(16),
    oplace VARCHAR(16),

    br VARCHAR(16),
    lvl INT,
    ltyp VARCHAR(16),
    hp INT,
    mhp INT,
    mmhp INT,
    sstr INT,
    sint INT,
    sdex INT,
    god VARCHAR(50),
    dur BIGINT,
    turn BIGINT,
    urune INT,
    nrune INT,
    ttime DATETIME,
    rstart CHAR(15),
    rtime CHAR(15),

    -- Known milestones: abyss.enter, abyss.exit, rune, orb, ghost, uniq,
    -- uniq.ban, br.enter, br.end.
    verb VARCHAR(20),
    noun VARCHAR(100),

    -- The actual milestone message for Henzell to report.
    milestone VARCHAR(255),

    -- How many times it's been played on FooTV
    ntv INT DEFAULT 0,

    PRIMARY KEY(id),
    FOREIGN KEY (game_id) REFERENCES logrecord (id)
    ON DELETE SET NULL
);
CREATE INDEX mile_lookup_ext ON milestone (verb, noun);
CREATE INDEX mile_ind_foffset ON milestone (file, offset);
CREATE INDEX mile_lookup ON milestone (game_id, verb);
CREATE INDEX mile_game_id ON milestone (game_id);

CREATE TABLE spr_milestone AS
SELECT * FROM milestone LIMIT 1;
TRUNCATE TABLE spr_milestone;
ALTER TABLE spr_milestone ADD PRIMARY KEY (id);
ALTER TABLE spr_milestone CHANGE COLUMN id id BIGINT AUTO_INCREMENT;
CREATE INDEX spr_mile_lookup_ext ON spr_milestone (verb, noun);
CREATE INDEX spr_mile_ind_foffset ON spr_milestone (file, offset);
CREATE INDEX spr_mile_lookup ON spr_milestone (game_id, verb);
CREATE INDEX spr_mile_game_id ON spr_milestone (game_id);

CREATE TABLE zot_milestone AS
SELECT * FROM milestone LIMIT 1;
TRUNCATE TABLE zot_milestone;
ALTER TABLE zot_milestone ADD PRIMARY KEY (id);
ALTER TABLE zot_milestone CHANGE COLUMN id id BIGINT AUTO_INCREMENT;
CREATE INDEX zot_mile_lookup_ext ON zot_milestone (verb, noun);
CREATE INDEX zot_mile_ind_foffset ON zot_milestone (file, offset);
CREATE INDEX zot_mile_lookup ON zot_milestone (game_id, verb);
CREATE INDEX zot_mile_game_id ON zot_milestone (game_id);

DROP TABLE IF EXISTS canary;
CREATE TABLE canary (
    last_update DATETIME
);