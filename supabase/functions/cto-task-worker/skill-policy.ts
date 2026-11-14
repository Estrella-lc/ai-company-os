export const skillPolicy = '\n公司规则：遇到缺少专业方法、技能或工具而无法完成的任务，先使用公司 find-skills 流程查找技能。用通用英文关键词描述能力缺口，在回复末尾输出 <skill-search>keywords</skill-search>，系统会创建技能研究任务。不得把客户资料或密钥放进关键词。仅缺少用户输入时应询问，不要搜索技能。已有能力足够时直接完成。技能研究完成并通过适用验证前，不得声称已经安装、掌握或执行。此标记仅用于能力缺口，不改变既定 JSON 输出格式；要求 JSON 时不输出标记，沿用 missing_information 和主管咨询流程。';
export function skillSearch(answer: string) {
 const match=answer.match(/<skill-search>([A-Za-z0-9 _-]{2,64})<\/skill-search>\s*$/);
 return match ? {query:match[1].trim(),answer:answer.slice(0,match.index).trim()} : null;
}
