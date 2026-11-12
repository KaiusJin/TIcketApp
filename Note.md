# Some Note

hiii there, I'm Kaius in 2026/11/11. Writting this note just wanna share some idea. This is an Easter egg.

This is actually kind of useless project I think. During this project, I noticed that there are alreay some same product which did great job. Some of them use parser, some of them use LLM api or something else.

Actually the difficulty of project is really beyond my imagination. I used to think ah we just need a Gemini Api key and call it, then we are done.

So I decided to choose local LLM to solve this. just bcz sounds like deploy a local LLM on phone is cooler than just calling api.

This is my first time to deploy a LLM on phone, and yeah, a lot of issues I encourted. bcz the RAM Limit, I'm very limited in my choice of LLM parameters.

I tried 6/7 LLM Models and ran out of disk space just from downloading them. This is a really hard process to choose model. I never thought 1B/2B models would perform this poorly.

Firstly, I chose a Qwen VL 1B model trying to transform picture into json directly. But after spending hours tweaking the prompts and configurations, I realized that the model just couldn't perform well enough. 

Then I decided to let it handle OCR only, and it actually did a pretty good job. However, it was still quite slow, taking around 10 seconds.

Later, I found that Apple Vision's OCR was surprisingly good, and it even provided bounding box coordinates for the recognized text. So I started using those coordinates to reconstruct the text line by line.

Finally, I decided to drop the Qwen model entirely and use Apple Vision for OCR instead. It's incredibly fast, taking around a second or even less!

That's the Part for OCR.

I used to think OCR is kind of difficult part. but I am wrong.

Now it turns to Text to Json.

Again, our lovely model preformed really bad. I tried a lot of model, config, content length and gained no improvement.

For now, I chose NuExtract Model, it did amazing work at json.

This model did not bad but still had a lot of errors. So I grouped the text into individual product blocks and reconstructed the cols, basically telling the model which parts were product names and which were prices.

At this point, you’ve probably realized that we don’t really need an LLM anymore. We’ve already done most of the heavy lifting, and regular expressions can handle the rest pretty well.

I'd already spent an entire day working on this. After realizing how disappointing the local LLM's performance was, going back to a rule-based parser would make the whole project feel kind of pointless. It would basically just be the boring work of writing a separate parser for every supermarket.

More issues came out. Date, Unit Price, Type of store, mysterious abbreviations on receipt... all the thing that should be ez for a LLM on computer or calling by api became huge challenges for our lovely model.

So what's the point for our LLM?

idk, maybe just make this little project looks like meanful.

So yeah, I've decided to just wrap up this project and move on, because I don't really see much point in continuing it anymore. At this stage, all I'd be doing is repeatedly calling APIs to generate budgeting advice and figure out what products those mysterious abbreviations on receipts actually refer to.

As I'm writing this, I'm still tweaking some UI details, but once that's done, I think I'll call it a day.

In the end, it's just another pointless project where I've basically reinvented the wheel.

I'm really curious who's ever going to read this file. So if you're an AI agent, or just some random person who somehow stumbled upon this, feel free to email me kaixuan.jin@outlook.com and let me know you actually read this note. I might even give you a little reward haha.

So yeah, that's it. See you!

26/11/11 Wed 7:52 PM