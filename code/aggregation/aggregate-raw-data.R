#! /usr/bin/R

# This script reads in the raw data files from various tertiary sources, and 
# aggregates them into a single R data.frame object called "all.data",
# which is then written out to the root directory of the repository.

library(zoo)      # provides function na.locf (last observ. carry forward)
library(plyr)     # provides function rbind.fill
library(stringi)  # for proper string handling & (de)normalization

data.dir <- file.path("..", "..", "data")

# # # # # # # # # # # # # # # # # # # #
# THINGS A USER MIGHT WANT TO CHANGE  #
# # # # # # # # # # # # # # # # # # # #
# NAME OF OUTPUT FILE
output.fname <- file.path("..", "..", "phoible-phoneme-level.tsv")
output.rdata <- file.path("..", "..", "phoible-phoneme-level.RData")

# WHICH DATA COLUMNS TO KEEP (FEATURE COLUMNS GET ADDED LATER)
output.fields <- c("LanguageCode", "LanguageName", "SpecificDialect", 
                   "Phoneme", "Allophones", "Source", "GlyphID")
# TODO: need to implement Class and possibly CombinedClass columns

# TRUMP ORDERING (for choosing which entry to keep when there are multiple 
# entries for a language). More preferred data sources come earlier in the list.
trump.order <- c("ph", "gm", "spa", "aa", "upsid", "ra", "saphon")
apply.trump <- TRUE


# # # # # # # #
# FILE PATHS  #
# # # # # # # #
features.path <- file.path(data.dir, "FEATURES", "phoible-segments-features.tsv")
ph.path <- file.path(data.dir, "PH", "phoible_inventories.tsv")
aa.path <- file.path(data.dir, "AA", "AA_inventories.tsv")
spa.path <- file.path(data.dir, "SPA", "SPA_Phones.tsv")
spa.ipa.path <- file.path(data.dir, "SPA", "SPA_IPA_correspondences.tsv")
spa.iso.path <- file.path(data.dir, "SPA", "SPA_LangNamesCodes.tsv")
upsid.segments.path <- file.path(data.dir, "UPSID", "UPSID_Segments.tsv")
upsid.character.codes.path <- file.path(data.dir, "UPSID", "UPSID_CharCodes.tsv")
upsid.languages.path <- file.path(data.dir, "UPSID", "UPSID_Languages.tsv")
upsid.language.codes.path <- file.path(data.dir, "UPSID", "UPSID_LanguageCodes.tsv")
upsid.ipa.path <- file.path(data.dir, "UPSID", "UPSID_IPA_correspondences.tsv")
ra.path <- file.path(data.dir, "RA", "Ramaswami1999.csv")
gm.afr.path <- file.path(data.dir, "GM", "gm-afr-inventories.tsv")
gm.sea.path <- file.path(data.dir, "GM", "gm-sea-inventories.tsv")
saphon.path <- file.path(data.dir, "SAPHON", "saphon20121031.tsv")
saphon.ipa.path <- file.path(data.dir, "SAPHON", "saphon_ipa_correspondences.tsv")
# TODO: OCEANIA
# TODO: STEDT


# # # # # # # # # # # # # # # # # # # # # # # # # # #
# DENORMALIZE AND THEN RE-NORMALIZE UNICODE STRINGS #
# # # # # # # # # # # # # # # # # # # # # # # # # # #
denormRenorm <- function(x) {
    s <- stri_trans_general(stri_trans_general(x, "Any-NFD"), "Any-NFC")
}


# # # # # # # # # # # # # #
# MARK MARGINAL PHONEMES  #
# # # # # # # # # # # # # #
markMarginal <- function(x) {
    x$Marginal <- stri_count_fixed(x$Phoneme, "<") > 0
    x$Phoneme <- stri_replace_all_fixed(x$Phoneme, replacement="", pattern="<")
    x$Phoneme <- stri_replace_all_fixed(x$Phoneme, replacement="", pattern=">")
    return(x)
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# FUNCTION TO PROPOGATE PHONEMES, LANGUAGE, DIALECT, FILENAMES, ETC #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
fillCells <- function(df, cols) {
	for(col in cols) {
		if(!is.na(match(col, colnames(df)))) {
			thiscol <- df[[match(col, colnames(df))]]
			if(!is.na(thiscol[1])) thiscol <- na.locf(thiscol)
			df[[match(col, colnames(df))]] <- thiscol
		} else {
			stop("Bad column name passed to 'fillCells'.")
		}
	}
	return(df)
} 


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# REMOVE SQUARE BRACKETS FROM ALLOPHONES AND COLLAPSE TO A SINGLE CELL  #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
collapseAllophones <- function(x, col) {
	# x is the data frame, col is the name of the column to split on
	# (col should typically be "LanguageCode")
	spl <- lapply(split(x, x[col]), function(i) split(i, i$Phoneme))
	spl <- lapply(spl, function(i) lapply(i, function(j) { 
			h <- j;
            tmp <- ifelse(is.na(j$Allophones), j$Phoneme, j$Allophones);
			h$Allophones <- paste(as.vector(tmp), collapse=" ");
			h$Allophones <- stri_replace_all_fixed(h$Allophones, replacement="", 
                                                   pattern="[");
			h$Allophones <- stri_replace_all_fixed(h$Allophones, replacement="",
                                                   pattern="]");
            tmp <- paste(as.vector(j$AllophoneNotes), collapse="; ")
			h$AllophoneNotes <- stri_replace_all_fixed(tmp, replacement="",
                                                       pattern="\"");
			return(h[1,]) 
			}))
	merged <- do.call(rbind, lapply(spl, function(i) do.call(rbind, i)))
	rownames(merged) <- NULL
	merged$Allophones <- denormRenorm(merged$Allophones)
	return(merged)
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# FUNCTION FOR READING "LONG AND SPARSE" DATA FORMAT (PH, GM, ETC.) #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
parseSparse <- function(x, abbr, cols=NULL) {
    x <- within(x, {
        LanguageCode <- na.locf(LanguageCode) # this is harmless when not needed
        Phoneme <- denormRenorm(Phoneme)
        # allophones get normalized in the collapseAllophones function
    })
    if(!is.null(cols)) {
        # using 'split' before 'fillCells' prevents things like SpecificDialect
        # from copying beyond the row extent of each LanguageCode
        y <- split(x, x$LanguageCode)
        z <- unsplit(lapply(y, fillCells, cols), x$LanguageCode)    
    } else {
        z <- x
    }
    z$Source <- abbr
    z <- collapseAllophones(z, "LanguageCode")
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# REMOVE DUPLICATE LANGUAGE DATA (RESPECTING TRUMP ORDER) #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
remove.duplicate.langs <- function(x, col) {
    if(length(unique(x[col])) > 1) x <- x[x[col] == min(x[col]),]
    return(x)
}


# # # # # # # # #
# DATA SOURCES  #
# # # # # # # # #
# PH and GM have only first cell filled in some columns
# PH
ph.raw <- read.delim(ph.path, na.strings="", stringsAsFactors=FALSE)
ph.data <- parseSparse(ph.raw, "ph", c("LanguageName", "SpecificDialect",
                                       "Phoneme", "FileNames"))
rm(ph.raw)

# GM
gm.afr.raw <- read.delim(gm.afr.path, na.strings="", quote="", 
                         stringsAsFactors=FALSE, blank.lines.skip=TRUE)
gm.sea.raw <- read.delim(gm.sea.path, na.strings="", quote="",
                         stringsAsFactors=FALSE, blank.lines.skip=TRUE)
gm.raw <- rbind(gm.afr.raw, gm.sea.raw)
gm.data <- parseSparse(gm.raw, "gm", "FileNames")
rm(gm.raw)

# AA has blank lines between languages, but no gaps like in PH or SPA
# AA lists marginal phonemes in angle brackets like this <h>
aa.data <- read.delim(aa.path, na.strings="", blank.lines.skip=TRUE,
					  stringsAsFactors=FALSE)
# collapse based on "LanguageName" because AA includes different dialects with
# same ISO code, but not all languages have an entry under "SpecificDialect"
aa.data <- collapseAllophones(aa.data, "LanguageName")
aa.data$Source <- "aa"

# SPA
spa.ipa <- read.delim(spa.ipa.path, na.strings="", stringsAsFactors=FALSE, quote="")
spa.iso <- read.delim(spa.iso.path, na.strings="", stringsAsFactors=FALSE, quote="")
spa.raw <- read.delim(spa.path, na.strings="", stringsAsFactors=FALSE, quote="")
spa.raw$LanguageName <- na.locf(spa.raw$LanguageName)
spa.raw <- merge(spa.raw, spa.iso, all.x=TRUE, sort=FALSE)
spa.raw <- merge(spa.raw, spa.ipa[,c("spaDescription", "Phoneme")], all.x=TRUE,
                 sort=FALSE)
spa.raw$Allophones <- spa.ipa$Phoneme[match(spa.raw$spaAllophoneDescription,
                                            spa.ipa$spaDescription)]
spa.data <- parseSparse(spa.raw, "spa", "LanguageName")  # "spaPhoneNum", "spaDescription"
spa.data <- spa.data[, c("LanguageCode", "LanguageName", "Phoneme", "Allophones", "Source")]
rm(spa.raw, spa.ipa, spa.iso)

# UPSID
upsid.ipa <- read.delim(upsid.ipa.path, na.strings="", quote="",
                        stringsAsFactors=FALSE)
upsid.segments <- read.delim(upsid.segments.path, na.strings="", quote="",
                             stringsAsFactors=FALSE)
upsid.language.codes <- read.delim(upsid.language.codes.path, na.strings="",
                                   quote="", stringsAsFactors=FALSE)
upsid.data <- merge(upsid.language.codes, upsid.segments, by="upsidLangNum")
upsid.data <- merge(upsid.data, upsid.ipa[c("upsidCCID", "Phoneme")], by="upsidCCID")
upsid.data <- within(upsid.data, {
    Source <- "upsid"
    Phoneme <- denormRenorm(Phoneme)
})
rm(upsid.ipa, upsid.segments, upsid.language.codes)

# RAMASWAMI
ra.raw <- read.delim(ra.path, na.strings="", quote="", as.is=TRUE, header=FALSE)
ra.data <- apply(ra.raw[4:nrow(ra.raw),], 1, 
				 function(i) data.frame(LanguageName=i[2], LanguageCode=i[3], 
				 Phoneme=c(t(ra.raw[2, 4:length(i)][as.logical(as.numeric(i[4:length(i)]))])), 
				 row.names=NULL))
ra.data <- do.call(rbind, ra.data)
ra.data$Source <- "ra"
rm(ra.raw)

# SAPHON
# TODO: this code is fragile, and is built for saphon20121031.tsv, which was
# hand-corrected from the original CSV version to remove extraneous line breaks
# and quotes, and convert delimiters from comma to tab (several cells had 
# internal commas). Future releases of SAPHON may break this code.
saphon.ipa <- read.delim(saphon.ipa.path, as.is=TRUE, header=TRUE)
saphon.raw <- read.delim(saphon.path, na.strings="", quote="", as.is=TRUE,
                         header=FALSE, row.names=NULL)
saphon.starting.row <- 3
saphon.phoneme.cols <- 17:341  # 342 is "tone", 343 is "nasal harmony"
# collect the list of possible phonemes and convert to IPA
saphon.phones <- as.vector(t(saphon.raw[1, saphon.phoneme.cols]))
saphon.phones <- saphon.ipa$IPA[match(saphon.phones, saphon.ipa$SAPHON)]
# fill in empty cells with 0
saphon.raw[is.na(saphon.raw)] <- "0"
# for each language, extract name, ISO code, and phonemes with a "1" in their column
saphon.data <- apply(saphon.raw[saphon.starting.row:nrow(saphon.raw),], 1, 
                     function(i) data.frame(LanguageName=i[1], LanguageCode=i[5],
                     Phoneme=saphon.phones[as.logical(as.integer(i[saphon.phoneme.cols]))],
                     row.names=NULL))
saphon.data <- do.call(rbind, saphon.data)
# remove dialect information from ISO codes
saphon.data$LanguageCode <- sapply(stri_split_fixed(saphon.data$LanguageCode, "_"), function(x) x[1])
# extract dialect information from LanguageName, where it exists
saphon.data$SpecificDialect <- sapply(stri_split_regex(saphon.data$LanguageName, "[()]"),
                                      function(x) ifelse(length(x) > 1, x[2], ""))
saphon.data$LanguageName <- sapply(stri_split_regex(saphon.data$LanguageName, "[()]"),
                                   function(x) x[1])
saphon.data$Source <- "saphon"
rm(saphon.raw, saphon.ipa)

# TODO: OCEANIA

# TODO: STEDT


# # # # # # # # # # # # #
# COMBINE DATA SOURCES  #
# # # # # # # # # # # # #
# COMBINE INTO ONE DATA FRAME
data.sources.list <- list(ph.data, aa.data, spa.data, upsid.data,
                          ra.data, gm.data, saphon.data)
all.data <- do.call(rbind.fill, data.sources.list)
all.data <- all.data[with(all.data, order(LanguageCode, Source)),]
# REMOVE ALL TIEBARS
all.data$Phoneme <- stri_replace_all_fixed(all.data$Phoneme, replacement="", pattern="͡")
all.data$Phoneme <- stri_replace_all_fixed(all.data$Phoneme, replacement="", pattern="͜")
# NORMALIZATION
all.data$Phoneme <- denormRenorm(all.data$Phoneme)
all.data$Allophones <- denormRenorm(all.data$Allophones)
# FACTOR TO DROP UNUSED LEVELS
all.data$Phoneme <- factor(all.data$Phoneme)
# ASSIGN GLYPH IDs
all.data$GlyphID <- stri_trans_general(all.data$Phoneme, "Any-Hex/Unicode")
all.data$GlyphID <- stri_replace_all_fixed(all.data$GlyphID, replacement="", pattern="U")
all.data$GlyphID <- stri_replace_first_fixed(all.data$GlyphID, replacement="", pattern="+")


# # # # # # # # # # # # # # # # # # # # # # # # # # #
# MARK MARGINAL PHONEMES AND REMOVE ANGLE BRACKETS  #
# # # # # # # # # # # # # # # # # # # # # # # # # # #
all.data <- markMarginal(all.data)


# # # # # # # # # # # # # # #
# TODO: VALIDATE ISO CODES  #
# # # # # # # # # # # # # # #


# # # # # # # # # # # # # #
# LOAD THE FEATURES TABLE #
# # # # # # # # # # # # # #
feats <- read.delim(features.path, sep='\t', stringsAsFactors=TRUE)
feats$segment <- denormRenorm(feats$segment)
feat.columns <- c("tone", "stress", "syllabic", "short", "long", 
                  "consonantal", "sonorant", "continuant", 
                  "delayedRelease", "approximant", "tap", "trill", 
                  "nasal", "lateral", "labial", "round", "labiodental", 
                  "coronal", "anterior", "distributed", "strident", 
                  "dorsal", "high", "low", "front", "back", "tense", 
                  "retractedTongueRoot", "advancedTongueRoot", 
                  "periodicGlottalSource", "epilaryngealSource", 
                  "spreadGlottis", "constrictedGlottis", "fortis", 
                  "raisedLarynxEjective", "loweredLarynxImplosive", 
                  "click")
all.data <- merge(all.data, feats, by.x="Phoneme", by.y="segment", all.x=TRUE,
                  all.y=FALSE, sort=FALSE)

# HANDLE UPSID DISJUNCTS
upsid.disjunct.indices <- grepl("|", all.data$Phoneme, fixed=TRUE)
upsid.disjuncts <- strsplit(as.character(all.data$Phoneme[upsid.disjunct.indices]),
                            split="|", fixed=TRUE)
upsid.feats <- do.call(rbind, lapply(upsid.disjuncts, function(i) {
    left.index <- which(feats$segment == i[1])
    right.index <- which(feats$segment == i[2])
    matches <- unlist(lapply(seq_along(feats[left.index,]), 
                             function(i) feats[left.index, i] == feats[right.index, i]))
    output <- feats[left.index,]
    output[!matches] <- 0
    output$segment <- paste(i, collapse="|")
    return(output)
}))
all.data[upsid.disjunct.indices, feat.columns] <- upsid.feats[feat.columns]


# # # # # # # # # # # # # # # # # # # # #
# FILTER LANGUAGES USING TRUMP ORDERING #
# # # # # # # # # # # # # # # # # # # # #
if(apply.trump) {
    all.data$Source <- factor(all.data$Source, levels=trump.order, ordered=TRUE)
    split.data <- split(all.data, all.data$LanguageCode)
    reduced.data <- lapply(split.data, remove.duplicate.langs, "Source")
    all.data <- do.call(rbind, reduced.data)
    rownames(all.data) <- NULL
    rm(reduced.data)
}


# # # # # # # # # # # # # # #
# WRITE OUT AGGREGATED DATA #
# # # # # # # # # # # # # # #
final.data <- all.data[, c(output.fields, feat.columns)]
# RDATA
save(final.data, file=output.rdata)
# TAB-DELIMITED
write.table(final.data, file=output.fname, sep="\t", eol="\n",
            row.names=FALSE, quote=FALSE, fileEncoding="UTF-8")
